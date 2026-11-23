// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IEntryPoint {
    function depositTo(address account) external payable;
    function withdrawTo(address payable withdrawAddress, uint256 withdrawAmount) external;
    function getNonce(address sender, uint192 key) external view returns (uint256 nonce);
}

struct UserOperation {
    address sender;
    uint256 nonce;
    bytes initCode;
    bytes callData;
    uint256 callGasLimit;
    uint256 verificationGasLimit;
    uint256 preVerificationGas;
    uint256 maxFeePerGas;
    uint256 maxPriorityFeePerGas;
    bytes paymasterAndData;
    bytes signature;
}

contract TNUSDPaymaster is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IEntryPoint public immutable entryPoint;
    address public immutable tnusdToken;
    
    // Tasa de cambio base: 1 TNUSD = equivalente a Native Fee según decimales (6 decimales TNUSD)
    uint256 public exchangeRate; 

    event GasPaidInTNUSD(address indexed user, uint256 tnusdAmount, uint256 nativeGasCost);
    event ExchangeRateUpdated(uint256 newRate);

    constructor(address _entryPoint, address _tnusdToken, address _owner) Ownable(_owner) {
        entryPoint = IEntryPoint(_entryPoint);
        tnusdToken = _tnusdToken;
        exchangeRate = 1e12; // Tasa por defecto ajustada a decimales
    }

    /// @notice Ajusta la tasa de conversión entre TNUSD y el token nativo de la red
    function setExchangeRate(uint256 _newRate) external onlyOwner {
        exchangeRate = _newRate;
        emit ExchangeRateUpdated(_newRate);
    }

    /// @notice Permite al Admin depositar saldo nativo en el EntryPoint para respaldar el patrocinio
    function deposit() external payable onlyOwner {
        entryPoint.depositTo{value: msg.value}(address(this));
    }

    /// @notice Permite retirar el saldo nativo del EntryPoint
    function withdrawTo(address payable withdrawAddress, uint256 amount) external onlyOwner {
        entryPoint.withdrawTo(withdrawAddress, amount);
    }

    /// @notice Validación invocada por el EntryPoint antes de procesar la UserOp (Solo lectura/verificación)
    function validatePaymasterUserOp(
        UserOperation calldata userOp,
        bytes32 /* userOpHash */,
        uint256 maxCost
    ) external view returns (bytes memory context, uint256 validationData) {
        require(msg.sender == address(entryPoint), "Paymaster: Caller must be EntryPoint");

        // Calcular costo máximo equivalente en TNUSD
        uint256 tnusdAmountRequired = (maxCost * exchangeRate) / 1e18;

        // Validar saldo y allowance previo del usuario (sin modificar estado)
        require(
            IERC20(tnusdToken).balanceOf(userOp.sender) >= tnusdAmountRequired,
            "Paymaster: Insufficient TNUSD balance for gas"
        );
        require(
            IERC20(tnusdToken).allowance(userOp.sender, address(this)) >= tnusdAmountRequired,
            "Paymaster: Insufficient TNUSD allowance for paymaster"
        );

        // Pasar contexto necesario para el cobro en postOp
        context = abi.encode(userOp.sender, tnusdAmountRequired, maxCost);
        validationData = 0; // Validación exitosa
    }

    /// @notice Cobro efectivo y ajuste final ejecutado por el EntryPoint tras finalizar la transacción
    function postOp(
        uint8 /* mode */,
        bytes calldata context,
        uint256 actualGasCost
    ) external nonReentrant {
        require(msg.sender == address(entryPoint), "Paymaster: Caller must be EntryPoint");

        (address user, , ) = abi.decode(context, (address, uint256, uint256));

        // Calcular el costo real en TNUSD basado en el gas consumido
        uint256 actualTNUSDCost = (actualGasCost * exchangeRate) / 1e18;

        // Realizar la transferencia efectiva de TNUSD desde el usuario hacia el Paymaster
        IERC20(tnusdToken).safeTransferFrom(user, address(this), actualTNUSDCost);

        emit GasPaidInTNUSD(user, actualTNUSDCost, actualGasCost);
    }

    /// @notice Permite al administrador retirar los TNUSD recolectados por concepto de tarifas
    function withdrawTokens(address recipient, uint256 amount) external onlyOwner {
        IERC20(tnusdToken).safeTransfer(recipient, amount);
    }
}