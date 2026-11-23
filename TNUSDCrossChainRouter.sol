// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {OApp, MessagingFee, Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TNUSDCrossChainRouter
 * @notice Router OApp para LayerZero V2 diseñado para gestionar la sincronización de liquidez del Hub (BSC) hacia las redes satélite.
 */
contract TNUSDCrossChainRouter is OApp {
    
    // Dirección del contrato del token TNUSD en el Hub
    address public tnusdToken;

    // Eventos de seguimiento
    event LiquidityBroadcasted(uint32 indexed dstEid, uint256 liquidity);
    event TokenUpdated(address indexed newToken);

    constructor(
        address _endpoint, 
        address _owner, 
        address _tnusdToken
    ) OApp(_endpoint, _owner) Ownable(_owner) {
        tnusdToken = _tnusdToken;
    }

    /**
     * @notice Actualiza la dirección del token TNUSD vinculado
     */
    function setTnusdToken(address _tnusdToken) external onlyOwner {
        tnusdToken = _tnusdToken;
        emit TokenUpdated(_tnusdToken);
    }

    /**
     * @notice Transmite la liquidez / totalSupply actual del Hub hacia una lista de EIDs satélite mediante LayerZero V2
     * @param _dstEids Lista de Endpoint IDs de las redes destino
     * @param _options Opciones de ejecución de LayerZero (gas limit, etc.)
     */
    function broadcastLiquidity(
        uint32[] calldata _dstEids, 
        bytes calldata _options
    ) external payable {
        // Obtener el suministro total actual (liquidez global) de TNUSD en el Hub
        uint256 currentLiquidity = IERC20(tnusdToken).totalSupply();
        bytes memory payload = abi.encode(currentLiquidity);

        uint256 totalFeeRequired = 0;

        // Calcular la tarifa nativa total requerida para todos los destinos
        for (uint256 i = 0; i < _dstEids.length; i++) {
            MessagingFee memory fee = _quote(_dstEids[i], payload, _options, false);
            totalFeeRequired += fee.nativeFee;
        }

        require(msg.value >= totalFeeRequired, "Tarifa de gas nativo insuficiente para LayerZero");

        // Enviar el mensaje de sincronización a cada EID satélite
        for (uint256 i = 0; i < _dstEids.length; i++) {
            MessagingFee memory fee = _quote(_dstEids[i], payload, _options, false);
            
            _lzSend(
                _dstEids[i],
                payload,
                _options,
                fee,
                payable(msg.sender)
            );
            
            emit LiquidityBroadcasted(_dstEids[i], currentLiquidity);
        }
    }

    /**
     * @notice Implementación requerida por OApp para recibir mensajes cross-chain (si aplica)
     */
    function _lzReceive(
        Origin calldata /*_origin*/,
        bytes32 /*_guid*/,
        bytes calldata /*_message*/,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) internal override {
        // Lógica de recepción en caso de mensajes entrantes
    }
}