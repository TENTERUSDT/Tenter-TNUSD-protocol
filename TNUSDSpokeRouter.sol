// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface ITNUSDToken is IERC20 {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}

interface ILayerZeroEndpointV2 {
    struct MessagingParams {
        uint32 dstEid;
        bytes32 receiver;
        bytes message;
        bytes options;
        bool payInLzToken;
    }

    struct MessagingReceipt {
        bytes32 guid;
        uint64 nonce;
        MessagingFee fee;
    }

    struct MessagingFee {
        uint256 nativeFee;
        uint256 lzTokenFee;
    }

    function send(MessagingParams calldata _params, address _refundAddress) external payable returns (MessagingReceipt memory);
    function quote(MessagingParams calldata _params, address _sender) external view returns (MessagingFee memory);
}

/**
 * @title TNUSDSpokeRouter
 * @notice Router satélite para sincronizar liquidez cross-chain con el Hub en BNB Chain.
 */
contract TNUSDSpokeRouter is Ownable {

    address public endpoint;
    uint32 public immutable hubEid;
    ITNUSDToken public immutable tnusdToken;
    
    mapping(uint32 => bytes32) public peers;

    event CrossChainLiquidityRequested(uint32 indexed targetEid, address indexed sender, uint256 amount);
    event LiquiditySynchronized(uint32 indexed srcEid, uint256 targetLiquidity, uint256 mintedOrBurned);
    event PeerSet(uint32 indexed eid, bytes32 peer);
    event TokensRescued(address indexed token, address indexed to, uint256 amount);

    constructor(
        address _endpoint,
        address _owner,
        uint32 _hubEid,
        address _token
    ) Ownable(_owner) {
        endpoint = _endpoint;
        hubEid = _hubEid;
        tnusdToken = ITNUSDToken(_token);
    }

    function setPeer(uint32 _eid, bytes32 _peer) external onlyOwner {
        peers[_eid] = _peer;
        emit PeerSet(_eid, _peer);
    }

    function requestCrossChainSwap(
        uint256 _amount, 
        bytes calldata _options
    ) external payable returns (ILayerZeroEndpointV2.MessagingReceipt memory receipt) {
        bytes32 targetPeer = peers[hubEid];
        require(targetPeer != bytes32(0), "Hub peer not set");

        bytes memory payload = abi.encode(msg.sender, _amount);

        ILayerZeroEndpointV2.MessagingParams memory params = ILayerZeroEndpointV2.MessagingParams({
            dstEid: hubEid,
            receiver: targetPeer,
            message: payload,
            options: _options,
            payInLzToken: false
        });

        receipt = ILayerZeroEndpointV2(endpoint).send{value: msg.value}(params, msg.sender);

        emit CrossChainLiquidityRequested(hubEid, msg.sender, _amount);
    }

    // Función para recibir mensajes desde LayerZero Endpoint
    function lzReceive(
        uint32 _srcEid,
        bytes32 /*_sender*/,
        bytes calldata _message
    ) external {
        require(msg.sender == endpoint, "Only endpoint can call lzReceive");
        require(_srcEid == hubEid, "Unauthorized source network");

        uint256 targetLiquidity = abi.decode(_message, (uint256));
        uint256 currentSupply = tnusdToken.totalSupply();

        if (targetLiquidity > currentSupply) {
            uint256 amountToMint = targetLiquidity - currentSupply;
            tnusdToken.mint(address(this), amountToMint);
            emit LiquiditySynchronized(_srcEid, targetLiquidity, amountToMint);
        } else if (targetLiquidity < currentSupply) {
            uint256 amountToBurn = currentSupply - targetLiquidity;
            tnusdToken.burn(address(this), amountToBurn);
            emit LiquiditySynchronized(_srcEid, targetLiquidity, amountToBurn);
        }
    }

    /**
     * @notice Permite al owner rescatar tokens ERC20 enviados por error o atrapados en el contrato.
     * @param _token Dirección del token a rescatar.
     * @param _to Dirección de destino para los fondos.
     * @param _amount Cantidad de tokens a retirar.
     */
    function rescueTokens(address _token, address _to, uint256 _amount) external onlyOwner {
        require(_to != address(0), "Invalid destination address");
        IERC20(_token).transfer(_to, _amount);
        emit TokensRescued(_token, _to, _amount);
    }
}