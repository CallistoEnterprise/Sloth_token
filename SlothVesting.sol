// SPDX-License-Identifier: No License (None)
pragma solidity ^0.8.0;

/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * By default, the owner account will be the one that deploys the contract. This
 * can later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
abstract contract Ownable {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor () {
        _owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(owner() == msg.sender, "Ownable: caller is not the owner");
        _;
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

interface IERC223 {
    function mint(address _to, uint256 _amount) external;
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function burnFrom(address sender, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IERC223Recipient { 
/**
 * @dev Standard ERC223 function that will handle incoming token transfers.
 *
 * @param _from  Token sender address.
 * @param _value Amount of tokens.
 * @param _data  Transaction metadata.
 */
    function tokenReceived(address _from, uint _value, bytes memory _data) external;
}

contract Vesting is Ownable {
    address constant public vestedToken = address(1); // Sloth token

    struct Allocation {
        uint256 amount;             // amount of token
        uint256 unlockPercentage;   // percentage of initially unlocked token
        uint256 startVesting;       // Timestamp (unix time) when starts vesting. First vesting will be at this time
        uint256 vestingPercentage;  // percentage of tokens will be unlocked every interval (i.e. 10% per 30 days)
        uint256 vestingInterval;    // interval (in seconds) of vesting (i.e. 30 days)        
    }

    uint256 public totalAllocated;
    uint256 public totalClaimed;
    mapping(address => Allocation[]) public beneficiaries; // beneficiary => Allocation
    mapping(address => uint256) public claimedAmount;   // beneficiary => already claimed amount
    mapping(address => bool) public depositors; // address of users who has right to deposit and allocate tokens

    modifier onlyDepositor() {
        require(depositors[msg.sender], "Only depositors allowed");
        _;
    }

    event SetDepositor(address depositor, bool enable);
    event Claim(address indexed beneficiary, uint256 amount);
    event AddAllocation(
        address indexed to,         // beneficiary of tokens
        uint256 amount,             // amount of token
        uint256 unlockPercentage,   // percentage of initially unlocked token
        uint256 startVesting,       // Timestamp (unix time) when starts vesting. First vesting will be at this time
        uint256 vestingPercentage,  // percentage of tokens will be unlocked every interval (i.e. 10% per 30 days)
        uint256 vestingInterval     // interval (in seconds) of vesting (i.e. 30 days)        
    );
    event Rescue(address _token, uint256 _amount);

    constructor (address _depositor) {
        if (_depositor != address(0)) {
            depositors[_depositor] = true;
            emit SetDepositor(_depositor, true);            
        }
    }

    // Depositor has right to transfer token to contract and allocate token to the beneficiary
    function setDepositor(address depositor, bool enable) external onlyOwner {
        depositors[depositor] = enable;
        emit SetDepositor(depositor, enable);
    }

    function allocateTokens(
        address to, // beneficiary of tokens
        uint256 amount, // amount of token
        uint256 unlockPercentage,   // percentage of first token unlock at vesting start
        uint256 startVesting,       // Timestamp (unix time) when starts vesting. First vesting will be at this time
        uint256 vestingPercentage,  // percentage of tokens will be unlocked every interval (i.e. 10% per 30 days)
        uint256 vestingInterval     // interval (in seconds) of vesting (i.e. 30 days)
    )
        external
        onlyDepositor
    {
        
        //require(amount <= getUnallocatedAmount(), "Not enough tokens");
        //require(startVesting > block.timestamp, "startVesting in the past");
        IERC223(vestedToken).mint(address(this), amount);   // mint vesting token

        beneficiaries[to].push(Allocation(amount, unlockPercentage, startVesting, vestingPercentage, vestingInterval));
        totalAllocated += amount;
        // Check ERC223 compatibility of the beneficiary 
        if (isContract(to)) {
            IERC223Recipient(to).tokenReceived(address(this), 0, "");
        }

        emit AddAllocation(to, amount, unlockPercentage, startVesting, vestingPercentage, vestingInterval);
    }

    function claim() external {
        claimBehalf(msg.sender);
    }

    function claimBehalf(address beneficiary) public {
        uint256 unlockedAmount = getUnlockedAmount(beneficiary);
        require(unlockedAmount != 0, "No unlocked tokens");
        claimedAmount[beneficiary] += unlockedAmount;
        totalClaimed += unlockedAmount;
        safeTransfer(vestedToken, beneficiary, unlockedAmount);
        emit Claim(beneficiary, unlockedAmount);
    }

    function getUnlockedAmount(address beneficiary) public view returns(uint256 unlockedAmount) {
        for (uint256 i = 0; i < beneficiaries[beneficiary].length; i++) {
            Allocation storage b = beneficiaries[beneficiary][i];
            uint256 amount = b.amount;
            uint256 unlocked;
            if (b.startVesting <= block.timestamp) {
                unlocked = amount * b.unlockPercentage / 100;   // first unlock
                uint256 intervals = (block.timestamp - b.startVesting) / b.vestingInterval; // number of full intervals passed after startVesting
                unlocked = unlocked + (amount * intervals * b.vestingPercentage / 100);
            }
            if (unlocked > amount) unlocked = amount;
            unlockedAmount += unlocked;
        }
        unlockedAmount = unlockedAmount - claimedAmount[beneficiary];
    }

    function getUnallocatedAmount() public view returns(uint256 amount) {
        amount = IERC223(vestedToken).balanceOf(address(this));
        uint256 unclaimed = totalAllocated - totalClaimed;
        amount = amount - unclaimed;
    }

    function rescueTokens(address _token) onlyOwner external {
        uint256 amount;
        if (_token == vestedToken) {
            amount = getUnallocatedAmount();
        } else {
            amount = IERC223(_token).balanceOf(address(this));
        }

        safeTransfer(_token, msg.sender, amount);
        emit Rescue(_token, amount);
    }

    /**
     * @dev Returns true if `account` is a contract.
     *
     * This test is non-exhaustive, and there may be false-negatives: during the
     * execution of a contract's constructor, its address will be reported as
     * not containing a contract.
     *
     * > It is unsafe to assume that an address for which this function returns
     * false is an externally-owned account (EOA) and not a contract.
     */
    function isContract(address account) internal view returns (bool) {
        // This method relies in extcodesize, which returns 0 for contracts in
        // construction, since the code is only stored at the end of the
        // constructor execution.

        uint256 size;
        // solhint-disable-next-line no-inline-assembly
        assembly { size := extcodesize(account) }
        return size > 0;
    }
    
    function safeTransfer(address token, address to, uint value) internal {
        // bytes4(keccak256(bytes('transfer(address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'TransferHelper: TRANSFER_FAILED');
    }
}