// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { ERC20PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import { ERC20PermitUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { OFTUpgradeable } from "@layerzerolabs/oft-evm-upgradeable/contracts/oft/OFTUpgradeable.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract TenterUSD is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ERC20PausableUpgradeable,
    ERC20PermitUpgradeable,
    OFTUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant RECOVERY_ROLE = keccak256("RECOVERY_ROLE");
    bytes32 public constant BLACKLISTER_ROLE = keccak256("BLACKLISTER_ROLE");
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    bytes32 public constant RESCUER_ROLE = keccak256("RESCUER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    mapping(address => bool) private _blacklisted;

    event Blacklisted(address indexed account, string reason);
    event Unblacklisted(address indexed account, string reason);
    event ClawbackExecuted(address indexed from, address indexed to, uint256 amount, string courtOrderRef);
    event TokensRescued(address indexed token, address indexed to, uint256 amount);
    event NativeRescued(address indexed to, uint256 amount);

    error AccountIsBlacklisted(address account);
    error AccountNotBlacklisted(address account);
    error TransferToZeroAddress();
    error InvalidRescueToken();
    error Unauthorized();
    error NativeTransferFailed();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _lzEndpoint) OFTUpgradeable(_lzEndpoint) {
        _disableInitializers();
    }

    function initialize(address defaultAdmin, address delegate) public initializer {
        if (defaultAdmin == address(0) || delegate == address(0)) revert TransferToZeroAddress();

        __OFT_init("Tenter USD", "TNUSD", delegate);
        __ERC20Pausable_init();
        __ERC20Permit_init("Tenter USD");
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(MINTER_ROLE, defaultAdmin);
        _grantRole(BURNER_ROLE, defaultAdmin);
        _grantRole(PAUSER_ROLE, defaultAdmin);
        _grantRole(GUARDIAN_ROLE, defaultAdmin);
        _grantRole(RECOVERY_ROLE, defaultAdmin);
        _grantRole(BLACKLISTER_ROLE, defaultAdmin);
        _grantRole(COMPLIANCE_ROLE, defaultAdmin);
        _grantRole(RESCUER_ROLE, defaultAdmin);
        _grantRole(UPGRADER_ROLE, defaultAdmin);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    modifier onlyComplianceOr(bytes32 role) {
        if (!hasRole(role, msg.sender) && !hasRole(COMPLIANCE_ROLE, msg.sender)) {
            revert Unauthorized();
        }
        _;
    }

    function mint(address to, uint256 amount) public onlyRole(MINTER_ROLE) {
        if (to == address(0)) revert TransferToZeroAddress();
        if (_blacklisted[to]) revert AccountIsBlacklisted(to);
        _mint(to, amount);
    }

    function burn(uint256 amount) public {
        if (_blacklisted[msg.sender]) revert AccountIsBlacklisted(msg.sender);
        _burn(msg.sender, amount);
    }

    function burnFrom(address account, uint256 amount) public virtual onlyRole(BURNER_ROLE) {
        _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
    }

    function burnFromBlacklisted(address account, uint256 amount) external onlyComplianceOr(RECOVERY_ROLE) {
        if (!isBlacklisted(account)) {
            revert AccountNotBlacklisted(account);
        }
        _burn(account, amount);
    }

    function blacklistWithReason(address account, string calldata reason) public onlyComplianceOr(BLACKLISTER_ROLE) {
        _blacklisted[account] = true;
        emit Blacklisted(account, reason);
    }

    function unblacklistWithReason(address account, string calldata reason) public onlyComplianceOr(BLACKLISTER_ROLE) {
        _blacklisted[account] = false;
        emit Unblacklisted(account, reason);
    }

    function isBlacklisted(address account) public view returns (bool) {
        return _blacklisted[account];
    }

    function clawbackWithReason(
        address from,
        address to,
        uint256 amount,
        string calldata courtOrderRef
    ) public onlyComplianceOr(RECOVERY_ROLE) {
        if (!isBlacklisted(from)) revert AccountNotBlacklisted(from);
        if (to == address(0)) revert TransferToZeroAddress();

        _transfer(from, to, amount);
        emit ClawbackExecuted(from, to, amount, courtOrderRef);
    }

    function rescueERC20(address tokenAddress, address to, uint256 amount) external onlyRole(RESCUER_ROLE) {
        if (tokenAddress == address(this)) revert InvalidRescueToken();
        if (to == address(0)) revert TransferToZeroAddress();

        IERC20(tokenAddress).safeTransfer(to, amount);
        emit TokensRescued(tokenAddress, to, amount);
    }

    function rescueNative(address payable to, uint256 amount) external onlyRole(RESCUER_ROLE) {
        if (to == address(0)) revert TransferToZeroAddress();
        (bool success, ) = to.call{value: amount}("");
        if (!success) revert NativeTransferFailed();
        emit NativeRescued(to, amount);
    }

    function pause() external {
        if (!hasRole(PAUSER_ROLE, msg.sender) && !hasRole(GUARDIAN_ROLE, msg.sender)) {
            revert Unauthorized();
        }
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // CORRECCIÓN: Resolución estricta de herencia usando ERC20Upgradeable y ERC20PausableUpgradeable
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20PausableUpgradeable)
    {
        if (from != address(0) && isBlacklisted(from)) {
            revert AccountIsBlacklisted(from);
        }
        if (to != address(0) && isBlacklisted(to)) {
            revert AccountIsBlacklisted(to);
        }

        super._update(from, to, value);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    receive() external payable {}
}