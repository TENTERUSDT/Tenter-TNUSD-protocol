// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ITNUSD is IERC20 {
    function mint(address to, uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
}

/**
 * @title TenterPSM_V3
 * @notice Módulo de Estabilidad de Paridad (PSM) institucional para Tenter USD (TNUSD).
 * Acuña y quema TNUSD 1:1 contra tokens de reserva con factor de escala explícito, techo de seguridad y comisiones configurables.
 */
contract TenterPSM_V3 is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    ITNUSD public immutable tnusd;
    IERC20 public immutable reserveToken;
    uint256 public immutable scaleFactor; // 1 para reservas de 6 decimales, 10^12 para reservas de 18 decimales

    uint256 public maxMintCap;      // Techo máximo en unidades TNUSD (6 decimales)
    uint256 public currentMinted;   // Acuñación neta activa por este contrato

    // --- Módulo de Comisiones (Basis Points: 100 = 1%, 10000 = 100%) ---
    uint256 public constant MAX_BPS = 10000;
    uint256 public mintFeeBps;      // Comisión de entrada (tin) al acuñar TNUSD
    uint256 public redeemFeeBps;    // Comisión de salida (tout) al redimir reserva
    address public feeRecipient;    // Dirección de tesorería que recibe las comisiones

    event SwapReserveToTNUSD(address indexed user, uint256 amountReserve, uint256 amountTNUSD, uint256 feeAmount, uint256 newCurrentMinted);
    event SwapTNUSDToReserve(address indexed user, uint256 amountTNUSD, uint256 amountReserve, uint256 feeAmount, uint256 newCurrentMinted);
    event MaxMintCapUpdated(uint256 oldCap, uint256 newCap);
    event FeesUpdated(uint256 newMintFeeBps, uint256 newRedeemFeeBps, address newFeeRecipient);

    error ExceedsMaxMintCap(uint256 requested, uint256 availableCap);
    error ZeroAmount();
    error InsufficientReserveInContract(uint256 requested, uint256 available);
    error InvalidFee();
    error InvalidRecipient();

    constructor(
        address _tnusd,
        address _reserveToken,
        uint256 _initialMaxMintCap,
        address _initialAdmin,
        uint256 _scaleFactor,
        uint256 _initialMintFeeBps,
        uint256 _initialRedeemFeeBps,
        address _initialFeeRecipient
    ) {
        require(_tnusd != address(0) && _reserveToken != address(0), "Invalid addresses");
        require(_scaleFactor > 0, "Invalid scale factor");
        if (_initialFeeRecipient == address(0)) revert InvalidRecipient();
        if (_initialMintFeeBps > 500 || _initialRedeemFeeBps > 500) revert InvalidFee(); // Tope máximo inicial del 5%

        tnusd = ITNUSD(_tnusd);
        reserveToken = IERC20(_reserveToken);
        scaleFactor = _scaleFactor;
        maxMintCap = _initialMaxMintCap;
        mintFeeBps = _initialMintFeeBps;
        redeemFeeBps = _initialRedeemFeeBps;
        feeRecipient = _initialFeeRecipient;

        _grantRole(DEFAULT_ADMIN_ROLE, _initialAdmin);
        _grantRole(GOVERNOR_ROLE, _initialAdmin);
    }

    /**
     * @notice Deposita reserva, deduce la comisión de entrada y acuña Tenter USD (TNUSD) 1:1 hasta el maxMintCap.
     * @param _tnusdAmount Cantidad de TNUSD deseada (expresada en 6 decimales).
     */
    function swapReserveToTNUSD(uint256 _tnusdAmount) external nonReentrant whenNotPaused {
        if (_tnusdAmount == 0) revert ZeroAmount();

        if (currentMinted + _tnusdAmount > maxMintCap) {
            revert ExceedsMaxMintCap(_tnusdAmount, maxMintCap - currentMinted);
        }

        uint256 grossReserveRequired = _tnusdAmount * scaleFactor;
        uint256 feeAmount = (grossReserveRequired * mintFeeBps) / MAX_BPS;
        uint256 netReserveToContract = grossReserveRequired - feeAmount;

        currentMinted += _tnusdAmount;

        // 1. Recibe el token de reserva neto en el contrato y transfiere la comisión a la tesorería
        reserveToken.safeTransferFrom(msg.sender, address(this), netReserveToContract);
        if (feeAmount > 0) {
            reserveToken.safeTransferFrom(msg.sender, feeRecipient, feeAmount);
        }

        // 2. Acuña TNUSD (6 decimales) directamente al usuario
        tnusd.mint(msg.sender, _tnusdAmount);

        emit SwapReserveToTNUSD(msg.sender, grossReserveRequired, _tnusdAmount, feeAmount, currentMinted);
    }

    /**
     * @notice Quema Tenter USD (TNUSD) del usuario y libera reserva descontando la comisión de salida.
     * @param _tnusdAmount Cantidad de TNUSD a redimir (en 6 decimales).
     */
    function swapTNUSDToReserve(uint256 _tnusdAmount) external nonReentrant whenNotPaused {
        if (_tnusdAmount == 0) revert ZeroAmount();

        uint256 grossReserveToReturn = _tnusdAmount * scaleFactor;
        uint256 feeAmount = (grossReserveToReturn * redeemFeeBps) / MAX_BPS;
        uint256 netReserveToUser = grossReserveToReturn - feeAmount;

        uint256 contractReserveBalance = reserveToken.balanceOf(address(this));

        if (grossReserveToReturn > contractReserveBalance) {
            revert InsufficientReserveInContract(grossReserveToReturn, contractReserveBalance);
        }

        if (currentMinted >= _tnusdAmount) {
            currentMinted -= _tnusdAmount;
        } else {
            currentMinted = 0;
        }

        // 1. Quema los TNUSD desde la wallet del usuario (requiere approve previo)
        tnusd.burnFrom(msg.sender, _tnusdAmount);

        // 2. Transfiere el neto de reserva al usuario y la comisión a la tesorería
        reserveToken.safeTransfer(msg.sender, netReserveToUser);
        if (feeAmount > 0) {
            reserveToken.safeTransfer(feeRecipient, feeAmount);
        }

        emit SwapTNUSDToReserve(msg.sender, _tnusdAmount, netReserveToUser, feeAmount, currentMinted);
    }

    // --- Gobernanza y Seguridad ---

    function setFees(uint256 _newMintFeeBps, uint256 _newRedeemFeeBps, address _newFeeRecipient) external onlyRole(GOVERNOR_ROLE) {
        if (_newMintFeeBps > 1000 || _newRedeemFeeBps > 1000) revert InvalidFee(); // Tope máximo de seguridad del 10%
        if (_newFeeRecipient == address(0)) revert InvalidRecipient();

        mintFeeBps = _newMintFeeBps;
        redeemFeeBps = _newRedeemFeeBps;
        feeRecipient = _newFeeRecipient;

        emit FeesUpdated(_newMintFeeBps, _newRedeemFeeBps, _newFeeRecipient);
    }

    function setMaxMintCap(uint256 _newCap) external onlyRole(GOVERNOR_ROLE) {
        emit MaxMintCapUpdated(maxMintCap, _newCap);
        maxMintCap = _newCap;
    }

    function pause() external onlyRole(GOVERNOR_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GOVERNOR_ROLE) {
        _unpause();
    }

    function emergencyWithdraw(address _token, uint256 _amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC20(_token).safeTransfer(msg.sender, _amount);
    }
}