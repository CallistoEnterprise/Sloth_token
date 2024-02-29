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



contract MigrationCE is Ownable {
    address constant public CLOE = address(0x1eAa43544dAa399b87EEcFcC6Fa579D5ea4A6187);
    address constant public CE = address(0x3986E815F87feA74910F7aDeAcD1cE7f172E1df0);

    uint256 public cloeRate = 30000;     // rate in percentage with 2 decimals. CE amount = CLOE amount * cloeRate / 10000
    bool public isPause;
    uint256 public totalCEMinted;
    uint256 public totalCLOEMigrated;

    event Migrate(address user, uint256 CLOEAmount, uint256 CEAmount);

    modifier migrationAllowed() {
        require(!isPause, "Migration is paused");
        _;
    }

    function tokenReceived(address, uint, bytes memory) external pure returns(bytes4) {
        revert("not allowed");
    }

    function migrateCLOE(address user, uint256 amount) external migrationAllowed {
        IERC223(CLOE).transferFrom(msg.sender, address(this), amount);
        uint256 ceAmount = amount * cloeRate / 10000;
        totalCLOEMigrated += amount;
        totalCEMinted += ceAmount;
        IERC223(CE).mint(msg.sender, ceAmount);  
        emit Migrate(user, amount, ceAmount); 
    }

    function setPause(bool pause) external onlyOwner {
        isPause = pause;
    }
    
    // rate in percentage with 2 decimals. CE amount = CLOE amount * cloeRate / 10000
    function setCloeRate(uint256 _cloeRate) external onlyOwner {
        cloeRate = _cloeRate;
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