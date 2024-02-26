// SPDX-License-Identifier: No License (None)
pragma solidity 0.8.19;

/**
 * @title Ownable
 * @dev The Ownable contract has an owner address, and provides basic authorization control
 * functions, this simplifies the implementation of "user permissions".
 *
 * Source https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-solidity/v2.1.3/contracts/ownership/Ownable.sol
 * This contract is copied here and renamed from the original to avoid clashes in the compiled artifacts
 * when the user imports a zos-lib contract (that transitively causes this contract to be compiled and added to the
 * build/artifacts folder) as well as the vanilla Ownable implementation from an openzeppelin version.
 */
contract Ownable {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev The Ownable constructor sets the original `owner` of the contract to the sender
     * account.
     */
    constructor () {
        _owner = msg.sender;
        emit OwnershipTransferred(address(0), _owner);
    }

    /**
     * @return the address of the owner.
     */
    function owner() public view returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(isOwner(),"Not Owner");
        _;
    }

    /**
     * @return true if `msg.sender` is the owner of the contract.
     */
    function isOwner() public view returns (bool) {
        return msg.sender == _owner;
    }

    /**
     * @dev Allows the current owner to relinquish control of the contract.
     * @notice Renouncing to ownership will leave the contract without an owner.
     * It will not be possible to call the functions with the `onlyOwner`
     * modifier anymore.
     */
    function renounceOwnership() public onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    /**
     * @dev Allows the current owner to transfer control of the contract to a newOwner.
     * @param newOwner The address to transfer ownership to.
     */
    function transferOwnership(address newOwner) public onlyOwner {
        _transferOwnership(newOwner);
    }

    /**
     * @dev Transfers control of the contract to a newOwner.
     * @param newOwner The address to transfer ownership to.
     */
    function _transferOwnership(address newOwner) internal {
        require(newOwner != address(0),"Zero address not allowed");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

interface IERC223 {
    function mint(address _to, uint256 _amount) external;
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function burnFrom(address sender, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

interface IStacking {
    struct Staker {
        uint256 amount;
        uint256 rewardPerSharePaid;
        uint64 endTime; // Time when staking ends and user may withdraw. After this time user will not receive rewards.
        uint64 index; // Balances indexed
        uint64 bonus;   // percent of bonus applied
        uint32 affiliatePercent; // percent of user's rewards that will be transferred to affiliate, i.e. 5% 
        uint32 noAffiliatePercent; // percent of user's rewards will be paid if no affiliate.
        address affiliate; // address of affiliate
    }
    function staker(address user) external view returns(Staker memory);
}

interface ISlothVesting {
    function allocateTokens(
        address to, // beneficiary of tokens
        uint256 amount // amount of token
    ) external;
}

interface IMigration {
    struct StakeRate {
        uint112 migratedAmount;
        uint112 reservedAmount;
        uint32 rate;
    }

    function stakingRateReserved(address user) external view returns(StakeRate memory);
}

contract MigrationStaking is Ownable {
    IMigration constant public MIGRATION = IMigration(0x346984a5a13241dAf2587571Ce7D86cEA77bfB7e);
    address constant public CLOE = address(0x1eAa43544dAa399b87EEcFcC6Fa579D5ea4A6187);
    address public slothVesting = address(0x98194aaA67638498547Df929DF4926C7D0DCD135);

    uint256 constant public startMigration = 1706745600;   // timestamp when migration start 1 February 2024 00:00:00 UTC

    bool public isPause;
    uint256 public totalSlothMinted;
    uint256[] public periodEnd = [1706831999,1706918399,1707004799,1707091199,1707177599,1707263999,1707350399,1714521599]; // last period will ends on 30 April 2024 23:59:59 UTC
    uint256[] public soyRatio = [200,400,800,1000,2000,4000,8000,10000];
    uint256[] public cloeRatio = [30,65,130,170,355,710,1415,1765];
    uint256 public totalCLOEMigrated;
    uint256 public totalSOYMigrated;
    
    struct StakeRate {
        uint112 migratedAmount;
        uint112 reservedAmount;
        uint32 rate;
    }

    address[] public stakingContracts = [0x86F7e2ef599690b64f0063b3F978ea6Ae2814f63,0x7d6C70b6561C31935e6B0dd77731FC63D5aC37F2,0x19DcB402162b6937a8ACEac87Ed6c05219c9bEf7,0x31bFf88C6124E1622f81b3Ba7ED219e5d78abd98];
    mapping(address user => StakeRate) public stakingRateReservedNew;
    uint256 public currentPeriod;

    event Migrate(address user, uint256 soyAmount, uint256 slothAmount);
    event MigrateCLOE(address user, uint256 cloeAmount, uint256 slothAmount);
    event StakingMigrate(address user, uint256 rate, uint256 migratedAmount, uint256 reservedAmount);
    event StakingFixRateMigration(address user, uint256 soyAmount, uint256 slothAmount);
    event SetPeriod(uint256 period, uint256 _periodEnd, uint256 _soyRatio, uint256 _cloeRatio);


    modifier migrationAllowed() {
        require(block.timestamp >= startMigration, "Migration is not started yet");
        require(!isPause, "Migration is paused");
        uint256 lastPeriod = periodEnd.length-1;
        while(periodEnd[currentPeriod] < block.timestamp) {
            require(currentPeriod < lastPeriod, "Migration finished");   // not a last period
            currentPeriod++;
        }
        _;
    }

    function getRates() external view returns(uint256 rateSOY, uint256 rateCLOE) {
        if(block.timestamp < startMigration) return (0,0);
        uint256 current = currentPeriod;
        uint256 lastPeriod = periodEnd.length-1;
        while(periodEnd[current] < block.timestamp) {
            if(current >= lastPeriod) return (0,0);
            current++;
        }
        rateSOY = soyRatio[current];
        rateCLOE = cloeRatio[current];
    }

    function tokenReceived(address, uint, bytes memory) external pure returns(bytes4) {
        revert("No Soy Migration");
    }

    function migrateCLOE(uint256 amount) external {
        IERC223(CLOE).burnFrom(msg.sender, amount);
        migrate(msg.sender, amount, false);
    }

    function migrate(address user, uint256 amount, bool isSoy) internal migrationAllowed {
        uint256 slothAmount;
        if(isSoy) {
            slothAmount = amount / soyRatio[currentPeriod];
            totalSOYMigrated += amount;
            emit Migrate(user, amount, slothAmount);
        } else {
            slothAmount = amount / cloeRatio[currentPeriod];
            totalCLOEMigrated += amount;
            emit MigrateCLOE(user, amount, slothAmount); 
        }
        totalSlothMinted += slothAmount;
        transferToVesting(user, slothAmount);       
    }

    function stakingMigrate() external {
        stakingMigrateBehalf(msg.sender);
    }

    function stakingMigrateBatch(address[] calldata users) external {
        uint len = users.length;
        for (uint i; i<len; i++)
            stakingMigrateBehalf(users[i]);
    }

    function stakingMigrateBehalf(address user) public migrationAllowed { 
        require(stakingRateReservedNew[user].rate == 0, "Already migrated");
        uint256 migratedAmount;
        IMigration.StakeRate memory oldMigration = MIGRATION.stakingRateReserved(user);
        if (oldMigration.rate == 0) {
            // do new migration
            for (uint i; i<4; i++) {
                IStacking.Staker memory s = IStacking(stakingContracts[i]).staker(user);
                migratedAmount += s.amount;
            }
            stakingRateReservedNew[user] = StakeRate(uint112(migratedAmount),uint112(0),uint32(soyRatio[currentPeriod]));
            migrate(user, migratedAmount, true);
            emit StakingMigrate(user, soyRatio[currentPeriod], migratedAmount, 0);
        } else if (oldMigration.reservedAmount != 0) {
            // migrate reserved amount
            migratedAmount = oldMigration.reservedAmount + oldMigration.migratedAmount;
            stakingRateReservedNew[user] = StakeRate(uint112(migratedAmount),uint112(0),uint32(oldMigration.rate));
            uint256 slothAmount = oldMigration.reservedAmount / oldMigration.rate;
            emit StakingFixRateMigration(user, oldMigration.reservedAmount, slothAmount); 
            totalSOYMigrated += oldMigration.reservedAmount;
            totalSlothMinted += slothAmount;
            transferToVesting(user, slothAmount);  
        } else 
        revert("Already migrated");
    }

    function stakingRateReserved(address user) public view returns (StakeRate memory stakeMigrated) {
        if (stakingRateReservedNew[user].rate == 0) {
            IMigration.StakeRate memory oldMigration = MIGRATION.stakingRateReserved(user);
            stakeMigrated.migratedAmount = oldMigration.migratedAmount;
            stakeMigrated.reservedAmount = oldMigration.reservedAmount;
            stakeMigrated.rate = oldMigration.rate;
        } else {
            return stakingRateReservedNew[user];
        }

    }

    function transferToVesting(address user, uint256 amount) internal {
        ISlothVesting(slothVesting).allocateTokens(user, amount);
    }

    function setPause(bool pause) external onlyOwner {
        isPause = pause;
    }
    
    function setSlothVesting(address _slothVesting) external onlyOwner {
        slothVesting = _slothVesting;
    }

    function setPeriod(uint256 period, uint256 _periodEnd, uint256 _soyRatio, uint256 _cloeRatio) external onlyOwner {
        if (period < periodEnd.length) {
            periodEnd[period] = _periodEnd;
            soyRatio[period] = _soyRatio;
            cloeRatio[period] = _cloeRatio;
        } else {
            periodEnd.push(_periodEnd);
            soyRatio.push(_soyRatio);
            cloeRatio.push(_cloeRatio);
        }
        emit SetPeriod(period, _periodEnd, _soyRatio, _cloeRatio);
    }

    function rescueERC20(address token, address to) external onlyOwner {
        uint256 value = IERC223(token).balanceOf(address(this));
        IERC223(token).transfer(to, value);
    }
}