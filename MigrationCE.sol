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

interface ICS2 {
    struct Staker
    {
        uint amount;
        uint time;              // Staking start time or last claim rewards
        uint multiplier;        // Rewards multiplier = 0.40 + (0.05 * rounds). [0.45..1] (max rounds 12)
        uint end_time;          // Time when staking ends and user may withdraw. After this time user will not receive rewards.
    }
    function staker(address user) external view returns(Staker memory);
}


contract MigrationCE is Ownable {
    ICS2 constant public CS2 = ICS2(0x08A7c8be47773546DC5E173d67B0c38AfFfa4b84);
    address constant public CLOE = address(0x1eAa43544dAa399b87EEcFcC6Fa579D5ea4A6187);
    uint256[] public periodEnd = [1712016000,1714521600,1719792000,1725235200]; // last period will ends on 1 September 2024 23:59:59 UTC
    address[] public tokenCE = [0x3986E815F87feA74910F7aDeAcD1cE7f172E1df0,0xB376e0eE3f4430ddE2cd6705eeCB48b2d5eb5C3C,0x54BdF1fB03f1ff159FE175EAe6cDCE25a2192F2E,0x4928688C4c83bC9a0D3c4a20A4BC13c54Af55C94]; // different tokens for each phase 
    uint256 public currentPeriod;

    uint256 public cloeRate = 20;     // CE amount = CLOE amount * cloeRate
    uint256 public cloRate = 1;     // CE amount = CLO amount * cloRate

    bool public isPause;
    uint256 public totalCEMinted;
    uint256 public totalCLOEMigrated;
    uint256 public totalCLOMigrated;

    struct ReserveCS {
        uint256 amount;
        uint256 time;
        address tokenCE;
    }

    mapping(address => ReserveCS) public reserves;

    event MigrateCLO(address user, uint256 CLOAmount, uint256 CEAmount, address ceAddress);
    event Migrate(address user, uint256 CLOEAmount, uint256 CEAmount, address ceAddress);

    modifier migrationAllowed() {
        require(!isPause, "Migration is paused");
        uint256 lastPeriod = periodEnd.length-1;
        while(periodEnd[currentPeriod] < block.timestamp) {
            require(currentPeriod < lastPeriod, "Migration finished");   // not a last period
            currentPeriod++;
        }
        _;
    }

    // migrate CLO to CE
    receive() external payable {
        require(cloRate != 0, "migration stopped");
        require(msg.value != 0, "0 value");
        address user = msg.sender;
        uint256 amount = msg.value;
        /*
        if (reserves[user].amount !=0 && reserves[user].time <= block.timestamp) {
            // migrate reserved amount of clo
            uint256 reserved = reserves[user].amount;
            if (amount >= reserved) {
                amount = amount - reserved;
                reserves[user].amount = 0;
            } else {
                reserves[user].amount = reserved - amount;
                reserved = amount;
                amount = 0;
            }
            uint256 ceAmount = reserved * cloRate;
            totalCLOMigrated += reserved;
            totalCEMinted += ceAmount;
            address ceAddress = reserves[user].tokenCE;
            IERC223(ceAddress).mint(user, ceAmount);
            emit MigrateCLO(user, reserved, ceAmount, ceAddress); 
        }
        */
        if (amount != 0) migrate(user, amount, false);
    }

    function migrateCLOE(address user, uint256 amount) external {
        require(amount != 0, "0 value");
        IERC223(CLOE).burnFrom(msg.sender, amount);
        migrate(user, amount, true);
    }

    function migrate(address user, uint256 amount, bool isCLOE) internal migrationAllowed {
        uint256 ceAmount;
        address ceAddress = tokenCE[currentPeriod];
        if (isCLOE) {
            ceAmount = amount * cloeRate;
            totalCLOEMigrated += amount;
            emit Migrate(user, amount, ceAmount, ceAddress); 
        } else {
            ceAmount = amount * cloRate;
            totalCLOMigrated += amount;
            emit MigrateCLO(user, amount, ceAmount, ceAddress); 
        }
        totalCEMinted += ceAmount;
        IERC223(ceAddress).mint(user, ceAmount); 
    }
/*
    function stakingMigrate(address user) public migrationAllowed onlyOwner { 
        require(reserves[user].time == 0, "Already reserved");
        ICS2.Staker memory s = CS2.staker(user);
        require(s.amount != 0, "No staking");
        reserves[user].amount = s.amount;
        reserves[user].time = s.end_time;
        reserves[user].tokenCE = tokenCE[currentPeriod];
    }

    function stakingRateReserved(address user) public view returns (uint256 reservedAmount) {
        return(reserves[user].amount);
    }
*/

    function setPause(bool pause) external onlyOwner {
        isPause = pause;
    }
    
    function setCloeCE(uint256 _cloeMigrated, uint256 _cloMigrated, uint256 _ceMinted) external onlyOwner {
        totalCLOEMigrated += _cloeMigrated;
        totalCLOMigrated += _cloMigrated;
        totalCEMinted += _ceMinted;
    }

    function setRates(uint256 _cloeRate, uint256 _cloRate) external onlyOwner {
        cloeRate = _cloeRate;
        cloRate = _cloRate;
    }

    // Rescue tokens
    event Rescue(address _token, uint256 _amount);

    function rescueTokens(address _token) external onlyOwner {
        uint256 _amount;
        if (_token == address(0)) {
            _amount = address(this).balance;
            safeTransferETH(msg.sender, _amount);
        } else {
            _amount = IERC223(_token).balanceOf(address(this));
            safeTransfer(_token, msg.sender, _amount);
        }
        emit Rescue(_token, _amount);
    }

    function safeTransfer(address token, address to, uint value) internal {
        // bytes4(keccak256(bytes('transfer(address,uint256)')));
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0xa9059cbb, to, value)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "TransferHelper: TRANSFER_FAILED"
        );
    }
    
    function safeTransferETH(address to, uint value) internal {
        (bool success,) = to.call{value:value}(new bytes(0));
        require(success, 'TransferHelper: ETH_TRANSFER_FAILED');
    }
}