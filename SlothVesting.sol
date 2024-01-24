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

contract SlothVesting is Ownable {
    address constant public vestingToken = address(0x7873d09AF3d6965988831C60c7D38DBbd2eAEAB0); // Sloth token
    uint256 constant public EndReward = 1769904000;     // end time to pay APR 1 February 2026 00:00:00 UTC

    struct Allocation {
        uint256 amount;             // amount of token
        uint256 startVesting;       // Timestamp (unix time) when starts vesting.
        uint256 lastClaimed;        // Timestamp when tokens were claimed last time
        uint256 alreadyClaimed;     // amount that were claimed already
    }

    uint256 public vestingPeriod = 90 days; // vesting period, before first tokens release
    uint256 public vestingInterval = 30 days;    // interval (in seconds) of vesting (i.e. 30 days)
    uint256 public vestingPercentage = 5;   // percentage of tokens will be unlocked every interval (i.e. 10% per 30 days)
    uint256 public vestingAPR = 15;         // APR on locked amount of tokens
    uint256 public totalAllocated;
    uint256 public totalClaimed;
    uint256 public totalAPR;
    mapping(address => Allocation) public beneficiaries; // beneficiary => Allocation
    mapping(address => bool) public depositors; // address of users who has right to deposit and allocate tokens

    modifier onlyDepositor() {
        require(depositors[msg.sender], "Only depositors allowed");
        _;
    }

    event SetDepositor(address depositor, bool enable);
    event Claim(address indexed beneficiary, uint256 amount, uint256 reward);
    event AddAllocation(
        address indexed to,         // beneficiary of tokens
        uint256 amount,             // amount of token
        uint256 startVesting       // Timestamp (unix time) when starts vesting.
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

    function setVestingParameters(uint256 _vestingPercentage, uint256 _vestingInterval, uint256 _vestingPeriod, uint256 _vestingAPR) external onlyOwner {
        vestingPercentage = _vestingPercentage;
        vestingInterval = _vestingInterval;
        vestingPeriod = _vestingPeriod;
        vestingAPR = _vestingAPR;
    }

    function allocateTokens(
        address to, // beneficiary of tokens
        uint256 amount // amount of token
    )
        external
        onlyDepositor
    {
        IERC223(vestingToken).mint(address(this), amount);   // mint vesting token
        if (beneficiaries[to].startVesting == 0) {  // new allocation 
            beneficiaries[to].amount = amount;
            beneficiaries[to].startVesting = block.timestamp;
            beneficiaries[to].lastClaimed = block.timestamp;
            // Check ERC223 compatibility of the beneficiary 
            safeTransfer(vestingToken, to, 0);
        }
        else beneficiaries[to].amount += amount;
        totalAllocated += amount;


        emit AddAllocation(to, amount, beneficiaries[to].startVesting);
    }

    function claim() external {
        claimBehalf(msg.sender);
    }

    function claimBehalf(address beneficiary) public {
        (uint256 unlockedAmount, uint256 reward) = getUnlockedAmount(beneficiary);
        require(unlockedAmount != 0, "No unlocked tokens");
        beneficiaries[beneficiary].alreadyClaimed += unlockedAmount;
        beneficiaries[beneficiary].lastClaimed = block.timestamp;
        totalClaimed += unlockedAmount;
        totalAPR += reward;
        IERC223(vestingToken).mint(beneficiary, reward);   // mint reward to beneficiary
        safeTransfer(vestingToken, beneficiary, unlockedAmount);
        emit Claim(beneficiary, unlockedAmount, reward);
    }

    function getUnlockedAmount(address beneficiary) public view returns(uint256 unlockedAmount, uint256 reward) {
        Allocation memory b = beneficiaries[beneficiary];
        if (b.lastClaimed + vestingInterval <= block.timestamp && b.startVesting + vestingPeriod < block.timestamp) {
            uint256 rewardEnd = (block.timestamp < EndReward) ? block.timestamp : EndReward;
            if (b.lastClaimed < rewardEnd)      // APR for locked tokens
                reward = (b.amount - b.alreadyClaimed) * vestingAPR * (rewardEnd - b.lastClaimed) / (100 * 365 days);
            if (b.lastClaimed == b.startVesting) b.lastClaimed = b.startVesting + vestingPeriod - vestingInterval;
            uint256 intervals = (block.timestamp - b.lastClaimed) / vestingInterval; // number of full intervals passed after startVesting
            unlockedAmount = b.amount * intervals * vestingPercentage / 100;
            if (unlockedAmount > b.amount) unlockedAmount = b.amount;
            unlockedAmount = unlockedAmount - b.alreadyClaimed;
        }
    }

    function rescueTokens(address _token) onlyOwner external {
        require(_token != vestingToken, "vestingToken not allowed");
        uint256 amount = IERC223(_token).balanceOf(address(this));
        safeTransfer(_token, msg.sender, amount);
        emit Rescue(_token, amount);
    }
    
    function safeTransfer(address token, address to, uint value) internal {
        // bytes4(keccak256(bytes('transfer(address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'TransferHelper: TRANSFER_FAILED');
    }
}