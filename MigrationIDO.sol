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

interface ISlothVesting {
    function allocateTokens(
        address to, // beneficiary of tokens
        uint256 amount // amount of token
    ) external;
}

contract MigrationIDO is Ownable {
    address constant public SOY = address(0x9FaE2529863bD691B4A7171bDfCf33C7ebB10a65);
    address public slothVesting = address(0xA1D58D570Afebd08Fc13a3983881Ac72a9857954);

    uint256 constant public startMigration = 1706745600;   // timestamp when migration start 1 February 2024 00:00:00 UTC
    uint256 public endMigration = 1714521599; // 30 April 2024 23:59:59 UTC
    uint256 public soyRatio = 100;
    bool public isPause;
    uint256 public totalSlothMinted;
    uint256 public totalSoyReserved;
    uint256 public totalSOYMigrated;
    mapping(address user => uint256 amount) public reserved;

    event Migrate(address user, uint256 soyAmount, uint256 slothAmount);
    event SetPeriod(uint256 endMigration, uint256 soyRatio);


    modifier migrationAllowed() {
        require(block.timestamp >= startMigration && block.timestamp <= endMigration, "Migration is closed");
        require(!isPause, "Migration is paused");
        _;
    }

    function tokenReceived(address _from, uint _value, bytes memory) external returns(bytes4) {
        require(msg.sender == SOY, "Only SOY");
        migrate(_from, _value);
        return this.tokenReceived.selector;
    }

    function migrate(address user, uint256 amount) internal migrationAllowed {
        uint256 reservedAmount = reserved[user];
        if(reservedAmount < amount) {
            uint256 rest = amount - reservedAmount;
            amount = reservedAmount;
            reserved[user] = 0;
            IERC223(SOY).transfer(user, rest);
        } else {
            reserved[user] = reservedAmount - amount;
        }
        uint256 slothAmount;
        slothAmount = amount / soyRatio;
        emit Migrate(user, amount, slothAmount);
        totalSOYMigrated += amount;
        totalSlothMinted += slothAmount;
        transferToVesting(user, slothAmount);       
    }

    function transferToVesting(address user, uint256 amount) internal {
        ISlothVesting(slothVesting).allocateTokens(user, amount);
    }


    function addReserved(address[] calldata users, uint256[] calldata amounts) external onlyOwner {
        uint256 len = users.length;
        uint256 total;
        require(amounts.length == len);
        for (uint i; i < len; i++) {
            reserved[users[i]] += amounts[i];
            total += amounts[i];
        }
        totalSoyReserved += total;
    }

    function replaceAddress(address oldAddress, address newAddress) external onlyOwner {
        uint256 value = reserved[oldAddress];
        reserved[oldAddress] = 0;
        reserved[newAddress] = value;
    }
    
    function setPause(bool pause) external onlyOwner {
        isPause = pause;
    }
    
    function setSlothVesting(address _slothVesting) external onlyOwner {
        slothVesting = _slothVesting;
    }

    function setPeriod(uint256 _endMigration, uint256 _soyRatio) external onlyOwner {
        endMigration = _endMigration;
        soyRatio = _soyRatio;
        emit SetPeriod(_endMigration, _soyRatio);
    }

    function burnSoy() external onlyOwner {
        uint256 value = IERC223(SOY).balanceOf(address(this));
        IERC223(SOY).transfer(0xdEad000000000000000000000000000000000000, value);
    }

    function rescueERC20(address token, address to) external onlyOwner {
        require(token != SOY, "wrong token");
        uint256 value = IERC223(token).balanceOf(address(this));
        IERC223(token).transfer(to, value);
    }
}