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
    function transfer(address recipient, uint256 amount) external returns (bool);
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

contract Migration is Ownable {
    address constant public SOY = address(0xE1A77164e5C6d9E0fc0b23D11e0874De6B328e68); //address(0x9FaE2529863bD691B4A7171bDfCf33C7ebB10a65);
    address constant public CLOE = address(0xd29588B55c9aCfEe50f52600Ae7C6a251cd9b145); //address(0x1eAa43544dAa399b87EEcFcC6Fa579D5ea4A6187);

    uint256 constant public startMigration = 1705786025; //1706745600;   // timestamp when migration start 1 February 2024 00:00:00 UTC

    bool public isPause;
    uint256 public totalSlothMinted;
    uint256[] public periodEnd = [1705881599,1705967999,1706054399,1706054499,1706054599,1706054699,1706054799,1706054899,1706745599]; // for test
    //uint256[] public periodEnd = [1706831999,1706918399,1707004799,1707091199,1707177599,1707263999,1707868799,1708473599,1714521599]; // last period will ends on 30 April 2024 23:59:59 UTC
    uint256[] public soyRatio = [100,200,400,800,1000,2000,4000,8000,10000];
    uint256[] public cloeRatio = [80,160,320,640,800,1600,3200,6400,8000];
    uint256 public totalCLOEMigrated;
    
    struct StakeRate {
        uint112 migratedAmount;
        uint112 reservedAmount;
        uint32 rate;
    }

    address[] public stakingContracts = [0x86F7e2ef599690b64f0063b3F978ea6Ae2814f63,0x7d6C70b6561C31935e6B0dd77731FC63D5aC37F2,0x19DcB402162b6937a8ACEac87Ed6c05219c9bEf7,0x31bFf88C6124E1622f81b3Ba7ED219e5d78abd98];
    mapping(address user => StakeRate) public stakingRateReserved;
    uint256 public currentPeriod;

    event Migrate(address user, uint256 soyAmount, uint256 slothAmount);
    event MigrateCLOE(address user, uint256 cloeAmount, uint256 slothAmount);
    event StakingMigrate(address user, uint256 rate, uint256 migratedAmount, uint256 reservedAmount);
    event StakingFixRateMigration(address user, uint256 soyAmount, uint256 slothAmount);
    event SetPeriod(uint256 period, uint256 _periodEnd, uint256 _soyRatio, uint256 _cloeRatio);


    modifier migrationAllowed() {
        require(block.timestamp >= startMigration, "Migration is not started yet");
        require(!isPause, "Migration is paused");
        while(periodEnd[currentPeriod] < block.timestamp) {
            require(currentPeriod < 8, "Migration finished");   // 8 - last period
            currentPeriod++;
        }
        _;
    }

    function tokenReceived(address _from, uint _value, bytes memory data) external returns(bytes4) {
        require(msg.sender == SOY, "Only SOY");
        if (keccak256(data) == keccak256("stakingFixRateMigration")) 
            stakingFixRateMigration(_from, _value);
        else
            migrate(_from, _value, true);
        return this.tokenReceived.selector;
    }

    function migrateCLOE(uint256 amount) external {
        IERC223(CLOE).burnFrom(msg.sender, amount);
        totalCLOEMigrated += amount;
        migrate(msg.sender, amount, false);
    }

    function migrate(address user, uint256 amount, bool isSoy) internal migrationAllowed {
        uint256 slothAmount;
        if(isSoy) {
            slothAmount = amount / soyRatio[currentPeriod];
            emit Migrate(user, amount, slothAmount);
        } else {
            slothAmount = amount / cloeRatio[currentPeriod];
            emit MigrateCLOE(user, amount, slothAmount); 
        }
        totalSlothMinted += slothAmount;
        transferToVesting(user, slothAmount);       
    }

    function stakingMigrate() external migrationAllowed {
        require(stakingRateReserved[msg.sender].rate == 0, "Already migrated");
        uint256 endMigration = periodEnd[8];    // 30 April 2024 23:59:59 UTC
        uint256 migratedAmount;
        uint256 reservedAmount;
        for (uint i; i<4; i++) {
            IStacking.Staker memory s = IStacking(stakingContracts[i]).staker(msg.sender);
            if(s.endTime > endMigration || (s.endTime == 0 && i != 0)) migratedAmount += s.amount;  // release time after and of migration and it's not a 30 days staking
            else reservedAmount += s.amount;
        }
        stakingRateReserved[msg.sender] = StakeRate(uint112(migratedAmount),uint112(reservedAmount),uint32(soyRatio[currentPeriod]));
        migrate(msg.sender, migratedAmount, true);
        emit StakingMigrate(msg.sender, soyRatio[currentPeriod], migratedAmount, reservedAmount);
    }

    function stakingFixRateMigration(address user, uint256 amount) internal {
            uint256 reservedAmount = stakingRateReserved[user].reservedAmount;
            require(reservedAmount >= amount, "Exceed reserved amount");
            uint256 slothAmount = amount / stakingRateReserved[user].rate;
            stakingRateReserved[user].reservedAmount = uint112(reservedAmount - amount);
            emit StakingFixRateMigration(user, amount, slothAmount); 
            totalSlothMinted += slothAmount;
            transferToVesting(user, slothAmount);       
    }

    function transferToVesting(address user, uint256 amount) internal {
        IERC223(0x7873d09AF3d6965988831C60c7D38DBbd2eAEAB0).mint(user, amount); // for testing
    }

    function setPause(bool pause) external onlyOwner {
        isPause = pause;
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
        require(token != SOY, "wrong token");
        uint256 value = IERC223(token).balanceOf(address(this));
        IERC223(token).transfer(to, value);
    }
}