pragma solidity ^0.4.0;

import "./SafeMath.sol";
import "./Math.sol";
import "./PlasmaRLP.sol";
import "./Merkle.sol";
import "./Validate.sol";
import "./PriorityQueue.sol";
import "zeppelin/contracts/token/ERC20.sol";


/**
 * @title PlasmaDEXRootChain
 * @dev This contract secures a utxo decentralized exchange plasma child chain to ethereum.
 */
contract RootChain {
    using SafeMath for uint256;
    using Merkle for bytes32;
    using PlasmaRLP for bytes;


    /*
     * Events
     */

    event Deposit(
        address indexed depositor,
        uint256 indexed depositBlock,
        address token,
        uint256 amount
    );

    event ExitStarted(
        address indexed exitor,
        uint256 indexed utxoPos,
        address token,
        uint256 amount
    );
    
    event ExitFinalized(
        address indexed exitor,
        uint256 indexed utxoPos,
        address token,
        uint256 amount
    );

    event Withdrawal(
        address indexed withdrawer,
        address token,
        uint256 amount
    );

    event BlockSubmitted(
        bytes32 root,
        uint256 timestamp
    );


    /*
     * Storage
     */
    bool public isEmergency = false;

    uint256 public constant CHILD_BLOCK_INTERVAL = 1000;

    address public operator;

    uint256 public currentChildBlock;
    uint256 public currentDepositBlock;
    uint256 public currentFeeExit;
    uint256 public challengePeriodTime;
    uint256 public minExitTime;
    
    ERC20 public token;

    mapping (uint256 => ChildBlock) public childChain;
    mapping (uint256 => Exit) public exits;
    mapping (address => address) public exitsQueues;
    mapping (address => mapping (address => uint256)) public approvedWithdrawals;  // mapping of currency address to a mapping of user address to approved withdrawals

    struct Exit {
        address owner;
        address token;
        uint256 amount;
    }

    struct ChildBlock {
        bytes32 root;
        uint256 timestamp;
    }


    /*
     * Modifiers
     */

    modifier onlyOperator() {
        require(msg.sender == operator);
        _;
    }
    
    modifier emergencyDeclared() {
        require(isEmergency);
	_;
    }

    modifier emergencyNotDeclared() {
        require(!isEmergency);
	_;
    }

    /*
     * @dev Constructor for the RootChain contract
     * @param _tokenAddress The address of the token smart contract that can be traded on the plasma dex
     */

    constructor(address _tokenAddress)
        public
    {
        operator = msg.sender;
        currentChildBlock = CHILD_BLOCK_INTERVAL;
        currentDepositBlock = 1;
        currentFeeExit = 1;
        exitsQueues[address(0)] = address(new PriorityQueue());
        exitsQueues[_tokenAddress] = address(new PriorityQueue());
        token = ERC20(_tokenAddress);

	// The challenge and min exit timess should be much longer (in the order of weeks, but they are currently set to
	// these values so that testing exits will be easier).
        // challengePeriodTime = 1 minutes;
        // minExitTime = 2 minutes;

        challengePeriodTime = 1 seconds;
        minExitTime = 2 seconds;
    }


    /*
     * Public Functions
     */

    /**
     * @dev Allows Plasma chain operator to submit block root.
     * @param _root The root of a child chain block.
     */
    function submitBlock(bytes32 _root)
        public
        onlyOperator
	emergencyNotDeclared
    {   
        childChain[currentChildBlock] = ChildBlock({
            root: _root,
            timestamp: block.timestamp
        });

        // Update block numbers.
        currentChildBlock = currentChildBlock.add(CHILD_BLOCK_INTERVAL);
        currentDepositBlock = 1;

        emit BlockSubmitted(_root, block.timestamp);
    }
    
    /**
     * @dev Allows anyone to deposit Eth into the Plasma chain.
     */
    function depositEth()
        public
        emergencyNotDeclared
        payable
    {
        deposit(address(0), msg.value);
    }
    
    /**
     * @dev Allows anyone to deposit tokens into the Plasma chain.
     * @param _amount The amount of tokens to deposit into the Plasma chain.
     */
    function depositToken(uint256 _amount)
        public
        emergencyNotDeclared
    {
        deposit(token, _amount);
        require(token.transferFrom(msg.sender, this, _amount));
    }

    /**
     * @dev Starts an exit from a deposit.
     * @param _depositPos UTXO position of the deposit.
     * @param _token Token type to deposit.
     * @param _amount Deposit amount.
     */
    function startDepositExit(uint256 _depositPos, address _token, uint256 _amount)
        public
        emergencyNotDeclared
    {
        uint256 blknum = _depositPos / 1000000000;

        // Check that the given UTXO is a deposit.
        require(blknum % CHILD_BLOCK_INTERVAL != 0);

        // Validate the given owner and amount.
        bytes32 root = childChain[blknum].root;
        bytes32 depositHash = keccak256(msg.sender, _token, _amount);
        require(root == depositHash);

        addExitToQueue(_depositPos, msg.sender, _token, _amount, childChain[blknum].timestamp);
    }

    /**
     * @dev Starts to exit a specified utxo.
     * @param _utxoPos The position of the exiting utxo in the format of blknum * 1000000000 + index * 10000 + oindex.
     * @param _txBytes The transaction being exited in RLP bytes format.
     * @param _proof Proof of the exiting transactions inclusion for the block specified by utxoPos.
     * @param _sigs Both transaction signatures and confirmations signatures used to verify that the exiting transaction has been confirmed.
     */
    function startExit(
        uint256 _utxoPos,
        bytes _txBytes,
        bytes _proof,
        bytes _sigs
    )
        public
        emergencyNotDeclared
    {
        uint256 blknum = _utxoPos / 1000000000;
        uint256 txindex = (_utxoPos % 1000000000) / 10000;
        uint256 oindex = _utxoPos - blknum * 1000000000 - txindex * 10000; 

        // Check the sender owns this UTXO.
        var exitingTx = _txBytes.createExitingTx(oindex);
        require(msg.sender == exitingTx.exitor);

        // Check the transaction was included in the chain and is correctly signed.
        bytes32 root = childChain[blknum].root; 
        bytes32 merkleHash = keccak256(keccak256(_txBytes), ByteUtils.slice(_sigs, 0, 130));
        require(Validate.checkSigs(keccak256(_txBytes), root, exitingTx.inputCount, _sigs));
        require(merkleHash.checkMembership(txindex, root, _proof));

        addExitToQueue(_utxoPos, exitingTx.exitor, exitingTx.token, exitingTx.amount, childChain[blknum].timestamp);
    }

    /**
     * @dev Allows anyone to challenge an exiting transaction by submitting proof of a double spend on the child chain.
     * @param _cUtxoPos The position of the challenging utxo.
     * @param _eUtxoIndex The output position of the exiting utxo.
     * @param _txBytes The challenging transaction in bytes RLP form.
     * @param _proof Proof of inclusion for the transaction used to challenge.
     * @param _sigs Signatures for the transaction used to challenge.
     * @param _confirmationSig The confirmation signature for the transaction used to challenge.
     */
    function challengeExit(
        uint256 _cUtxoPos,
        uint256 _eUtxoIndex,
        bytes _txBytes,
        bytes _proof,
        bytes _sigs,
        bytes _confirmationSig
    )
        public
        emergencyNotDeclared
    {
        uint256 eUtxoPos = _txBytes.getUtxoPos(_eUtxoIndex);
        uint256 txindex = (_cUtxoPos % 1000000000) / 10000;
        bytes32 root = childChain[_cUtxoPos / 1000000000].root;
        var txHash = keccak256(_txBytes);
        var confirmationHash = keccak256(txHash, root);
        var merkleHash = keccak256(txHash, _sigs);
        address owner = exits[eUtxoPos].owner;

        // Validate the spending transaction.
        require(owner == ECRecovery.recover(confirmationHash, _confirmationSig));
        require(merkleHash.checkMembership(txindex, root, _proof));

        // Delete the owner but keep the amount to prevent another exit.
        delete exits[eUtxoPos].owner;
    }

    /**
     * @dev Processes any exits that have completed the challenge period. 
     * @param _token Token type to process.
     */
    function finalizeExits(address _token)
        public
        emergencyNotDeclared
    {
        uint256 utxoPos;
        uint256 exitable_at;
	uint8 num_iterations = 0;

        // Check that we're exiting a known token.
        require(exitsQueues[_token] != address(0));

        (utxoPos, exitable_at) = getNextExit(_token);
        Exit memory currentExit;
        PriorityQueue queue = PriorityQueue(exitsQueues[_token]);
        while (exitable_at < block.timestamp) {
            currentExit = exits[utxoPos];

	    approvedWithdrawals[_token][currentExit.owner] = approvedWithdrawals[_token][currentExit.owner].add(currentExit.amount);
            
            emit ExitFinalized(currentExit.owner, utxoPos, _token, currentExit.amount);
            
            queue.delMin();
            delete exits[utxoPos].owner;

            if ((queue.currentSize() > 0) && (num_iterations < 10)) {
                (utxoPos, exitable_at) = getNextExit(_token);
            } else {
                return;
            }

	    num_iterations += 1;
        }
    }

    /**
     * @dev Function for user withdraw of eth or tokens.
     * @param _token Token type to withdrawal.
     */
    function withdraw(address _token) 
        public
        emergencyNotDeclared
    {
        uint256 withdrawalAmount = approvedWithdrawals[_token][msg.sender];

	if (withdrawalAmount > 0) {
	    approvedWithdrawals[_token][msg.sender] = 0;
    
            if (address(0) == _token) {
                msg.sender.transfer(withdrawalAmount);
            } else {
                ERC20 tokenObj = ERC20(_token);
                require(tokenObj.transfer(msg.sender, withdrawalAmount));
            }

	    emit Withdrawal(msg.sender, _token, withdrawalAmount);
        }
    }


    /* 
     * Public view functions
     */

    /**
     * @dev Queries the child chain.
     * @param _blockNumber Number of the block to return.
     * @return Child chain block at the specified block number.
     */
    function getChildChain(uint256 _blockNumber)
        public
        view
        returns (bytes32, uint256)
    {
        return (childChain[_blockNumber].root, childChain[_blockNumber].timestamp);
    }

    /**
     * @dev Determines the next deposit block number.
     * @return Block number to be given to the next deposit block.
     */
    function getDepositBlock()
        public
        view
        returns (uint256)
    {
        return currentChildBlock.sub(CHILD_BLOCK_INTERVAL).add(currentDepositBlock);
    }

    /**
     * @dev Returns information about an exit.
     * @param _utxoPos Position of the UTXO in the chain.
     * @return A tuple representing the active exit for the given UTXO.
     */
    function getExit(uint256 _utxoPos)
        public
        view
        returns (address, address, uint256)
    {
        return (exits[_utxoPos].owner, exits[_utxoPos].token, exits[_utxoPos].amount);
    }

    /**
     * @dev Determines the next exit to be processed.
     * @param _token Asset type to be exited.
     * @return A tuple of the position and time when this exit can be processed.
     */
    function getNextExit(address _token)
        public
        view
        returns (uint256, uint256)
    {
        uint256 priority = PriorityQueue(exitsQueues[_token]).getMin();
        uint256 utxoPos = uint256(uint128(priority));
        uint256 exitable_at = priority >> 128;
        return (utxoPos, exitable_at);
    }


    /*
     * Private functions
     */
     
    /**
     * @dev Helper function that will add a deposit block hash to the root chain.
     * @param _currency The address of the token that is being depositted.  Should be 0 if Eth is depositted.
     * @param _amount The total amount being deposited.
     */
    function deposit(address _currency, uint256 _amount)
        private
    {
        // Only allow up to CHILD_BLOCK_INTERVAL deposits per child block.
        require(currentDepositBlock < CHILD_BLOCK_INTERVAL);

        bytes32 root = keccak256(msg.sender, _currency, _amount);
        uint256 depositBlock = getDepositBlock();
        childChain[depositBlock] = ChildBlock({
            root: root,
            timestamp: block.timestamp
        });
        currentDepositBlock = currentDepositBlock.add(1);

        emit Deposit(msg.sender, depositBlock, _currency, _amount);
    }

    /**
     * @dev Adds an exit to the exit queue.
     * @param _utxoPos Position of the UTXO in the child chain.
     * @param _exitor Owner of the UTXO.
     * @param _token Token to be exited.
     * @param _amount Amount to be exited.
     * @param _created_at Time when the UTXO was created.
     */
    function addExitToQueue(
        uint256 _utxoPos,
        address _exitor,
        address _token,
        uint256 _amount,
        uint256 _created_at
    )
        private
    {
        // Check that we're exiting a known token.
        require(exitsQueues[_token] != address(0));

        // Calculate priority.
        uint256 exitable_at = Math.max(_created_at.add(minExitTime), block.timestamp.add(challengePeriodTime));
        uint256 priority = exitable_at << 128 | _utxoPos;
        
        // Check exit is valid and doesn't already exist.
        require(_amount > 0);
        require(exits[_utxoPos].amount == 0);

        PriorityQueue queue = PriorityQueue(exitsQueues[_token]);
        queue.insert(priority);

        exits[_utxoPos] = Exit({
            owner: _exitor,
            token: _token,
            amount: _amount
        });

        emit ExitStarted(msg.sender, _utxoPos, _token, _amount);
    }

    /*
     * Circuit Breaker functions
     */
    
    /**
     * @dev allows the operator to withdraw all the rootChain's ether and tokens, so that the deposted ether and tokens
     *      be distributed to the correct owners.
     */
    function emergencyWithdraw() 
        public 
	onlyOperator 
	emergencyDeclared
    {
        uint256 rootChainEthBalance = address(this).balance;
	uint256 rootChainTokenBalance = token.balanceOf(this);

	if (rootChainEthBalance > 0)
	    operator.transfer(rootChainEthBalance);

	if (rootChainTokenBalance > 0)
	    require(token.transfer(operator, rootChainTokenBalance));
    }

    /**
     * @dev a killswitch to stop the root chain and halt all deposits and withdrawals
     */
    function declareEmergency() 
        public 
	onlyOperator 
    {
        // set the killswitch bool to true
        isEmergency = true;
    }
}
