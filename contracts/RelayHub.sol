/* solhint-disable avoid-low-level-calls */
/* solhint-disable no-inline-assembly */
/* solhint-disable not-rely-on-time */
/* solhint-disable avoid-tx-origin */
/* solhint-disable bracket-align */
// SPDX-License-Identifier:MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "./utils/MinLibBytes.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "./utils/GsnEip712Library.sol";
import "./interfaces/GsnTypes.sol";
import "./interfaces/IRelayHub.sol";
import "./interfaces/IVerifier.sol";
import "./interfaces/IForwarder.sol";
import "./interfaces/IStakeManager.sol";
 
contract RelayHub is IRelayHub {
    using SafeMath for uint256;

    uint256 public override minimumStake;
    uint256 public override minimumUnstakeDelay;
    uint256 public override maximumRecipientDeposit;
    uint256 public override gasOverhead;
    uint256 public override maxWorkerCount;
    address override public penalizer;
    address override public stakeManager;
    string public override versionHub = "2.0.1+opengsn.hub.irelayhub";

    // maps relay worker's address to its manager's address
    mapping(address => address) public override workerToManager;

    // maps relay managers to the number of their workers
    mapping(address => uint256) public override workerCount;

    constructor (
        address _stakeManager,
        address _penalizer,
        uint256 _maxWorkerCount,
        uint256 _gasOverhead,
        uint256 _maximumRecipientDeposit,
        uint256 _minimumUnstakeDelay,
        uint256 _minimumStake
    ) public {
        stakeManager = _stakeManager;
        penalizer = _penalizer;
        maxWorkerCount = _maxWorkerCount;
        gasOverhead = _gasOverhead;
        maximumRecipientDeposit = _maximumRecipientDeposit;
        minimumUnstakeDelay = _minimumUnstakeDelay;
        minimumStake =  _minimumStake;
    }

    function registerRelayServer(uint256 baseRelayFee, uint256 pctRelayFee, string calldata url) external override {
        address relayManager = msg.sender;
        //Check if Relay Manager is staked
        /* solhint-disable-next-line avoid-low-level-calls */
        (bool succ,) = stakeManager.call(abi.encodeWithSelector(IStakeManager.requireManagerStaked.selector,
                relayManager,minimumStake,minimumUnstakeDelay));
        require(succ, "relay manager not staked" );

        require(workerCount[relayManager] > 0, "no relay workers");
        emit RelayServerRegistered(relayManager, baseRelayFee, pctRelayFee, url);
    }

    function addRelayWorkers(address[] calldata newRelayWorkers) external override {
        address relayManager = msg.sender;
        workerCount[relayManager] = workerCount[relayManager] + newRelayWorkers.length;
        require(workerCount[relayManager] <= maxWorkerCount, "too many workers");

        //Check if Relay Manager is staked
        /* solhint-disable-next-line avoid-low-level-calls */
        (bool succ,) = stakeManager.call(abi.encodeWithSelector(IStakeManager.requireManagerStaked.selector,
                relayManager,minimumStake,minimumUnstakeDelay));
        require(succ, "relay manager not staked" );


        for (uint256 i = 0; i < newRelayWorkers.length; i++) {
            require(workerToManager[newRelayWorkers[i]] == address(0), "this worker has a manager");
            workerToManager[newRelayWorkers[i]] = relayManager;
        }

        emit RelayWorkersAdded(relayManager, newRelayWorkers, workerCount[relayManager]);
    }


    function relayCall(
        GsnTypes.RelayRequest calldata relayRequest,
        bytes calldata signature    )
    external
    override
    {
        (signature);
        bytes memory relayedCallReturnValue;

        require(gasleft() >= gasOverhead.add(relayRequest.request.gas), "Not enough gas left");
        require(msg.sender == tx.origin, "RelayWorker cannot be a contract");
        require(workerToManager[msg.sender] != address(0), "Unknown relay worker");
        require(relayRequest.relayData.relayWorker == msg.sender, "Not a right worker");
         /* solhint-disable-next-line avoid-low-level-calls */
        (bool succ,) = stakeManager.call(abi.encodeWithSelector(IStakeManager.requireManagerStaked.selector,
                workerToManager[msg.sender],minimumStake,minimumUnstakeDelay));
        require(succ, "relay manager not staked" );
        //  require(relayRequest.relayData.gasPrice <= tx.gasprice, "Invalid gas price");
      
        bool forwarderSuccess;
        uint256 lastSuccTrx;

        
        (forwarderSuccess, lastSuccTrx, relayedCallReturnValue) = GsnEip712Library.execute(relayRequest, signature);          
        
        if ( !forwarderSuccess ) {
            revertWithStatus(RelayCallStatus.RejectedByForwarder, relayedCallReturnValue);
        }
       
       if (lastSuccTrx == 0) {// 0 == OK
                emit TransactionRelayed2(
                    workerToManager[msg.sender],
                    msg.sender,
                    keccak256(signature)
                );

                if ( relayedCallReturnValue.length>0 ) {
                    emit TransactionResult(relayedCallReturnValue);
                }
        }
        else{ 
            emit TransactionRelayedButRevertedByRecipient(            
            workerToManager[msg.sender],
            msg.sender,
            relayRequest.request.from,
            relayRequest.request.to,
            lastSuccTrx,
            relayRequest.relayData.isSmartWalletDeploy?bytes4(0):MinLibBytes.readBytes4(relayRequest.request.data, 0),
            relayedCallReturnValue);// TODO: debate if its neccesary to have lastSuccTrx
        }
    }


    /**
     * @dev Reverts the transaction with return data set to the ABI encoding of the status argument (and revert reason data)
     */
    function revertWithStatus(RelayCallStatus status, bytes memory ret) private pure {
        bytes memory data = abi.encode(status, ret);
       assembly {
            let dataSize := mload(data)
            let dataPtr := add(data, 32)
            revert(dataPtr, dataSize)
        }
    }

    function isRelayManagerStaked(address relayManager) public override returns (bool){
        /* solhint-disable-next-line avoid-low-level-calls */
        (bool succ,) = stakeManager.call(abi.encodeWithSelector(IStakeManager.requireManagerStaked.selector,
                relayManager,minimumStake,minimumUnstakeDelay));
        
        //If no revert, then return true
        require(succ, "relay manager not staked");
       
    }

    modifier penalizerOnly () {
        require(msg.sender == penalizer, "Not penalizer");
        _;
    }

    function penalize(address relayWorker, address payable beneficiary) external override penalizerOnly {
        address relayManager = workerToManager[relayWorker];
        // The worker must be controlled by a manager with a locked stake
        require(relayManager != address(0), "Unknown relay worker");
        require(
            isRelayManagerStaked(relayManager),
            "relay manager not staked"
        );
        IStakeManager.StakeInfo memory stakeInfo = IStakeManager(stakeManager).getStakeInfo(relayManager);
        IStakeManager(stakeManager).penalizeRelayManager(relayManager, beneficiary, stakeInfo.stake);
    }
}
