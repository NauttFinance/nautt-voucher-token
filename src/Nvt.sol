// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/*//////////////////////////////////////////////////////////////
                               ERRORS
//////////////////////////////////////////////////////////////*/
/*
 * Erros personalizados (mais baratos em gas que require + string).
 * - PaymentAlreadyMinted: barra reprocessamento de um pagamento já mintado — garante 1 pagamento = 1 NVT.
 * - TokenAlreadyClaimed:  impede resgatar o mesmo token duas vezes.
 * - ZeroAddress:          rejeita o endereço zero em entradas obrigatórias.
 * - NotImplemented:       stub temporário dos corpos ainda não escritos (mint/claim/rescue). Remover ao implementar.
 */
error PaymentAlreadyMinted(bytes32 paymentKey);
error TokenAlreadyClaimed(uint256 tokenId);
error ZeroAddress();
error NotImplemented();

/**
 * @title Nvt — Nautt Voucher Token
 * @notice Comprovante de pagamento (voucher) no padrão ERC-721 na Polygon. Registra que um cliente
 *         final pagou no cartão da Nautt e recebeu o produto/serviço — uma escrituração descentralizada.
 * @dev Modelo de escrow: o token é mintado para `address(this)` e custodiado pelo próprio contrato
 *      até o resgate (`claim`), quando a posse é transferida ao cliente uma única vez. Mint e claim
 *      são sempre executados pelo backend da Nautt (relayer); o cliente nunca assina nem paga gas.
 *      Nenhuma PII on-chain: o vínculo com o cliente é uma hash salgada do email calculada off-chain.
 */
contract Nvt is ERC721URIStorage, AccessControl, Pausable, ReentrancyGuard, IERC721Receiver {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    /*
     * Roles (constantes UPPER_SNAKE_CASE):
     * - MINTER_ROLE:   backend que consome o evento de pagamento (Kafka) e minta o voucher.
     * - OPERATOR_ROLE: serviço que executa o resgate após a confirmação por email.
     * - DEFAULT_ADMIN_ROLE (herdado do AccessControl): multisig da Nautt; concede/revoga roles, pause e rescue.
     * MINTER e OPERATOR são separados: comprometer um não permite abusar do outro.
     *
     * Storage (privado, prefixo s_; exposto via views explícitas de nome limpo):
     * - s_mintedPayments:       pagamento (keccak256(paymentId)) => tokenId gerado por ele.
     * - s_paymentAlreadyMinted: pagamento => já mintado? Separado do anterior para distinguir "não existe" do tokenId 0.
     * - s_tokensOfEmail:        emailHash (salgada, off-chain) => lista de tokenIds do cliente. Consulta central do resgate.
     * - s_isTokenClaimed:       tokenId => já resgatado? Impede resgate em duplicidade.
     * - s_nextTokenId:          contador do próximo tokenId livre.
     */
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    mapping(bytes32 => uint256) private s_mintedPayments;
    mapping(bytes32 => bool) private s_paymentAlreadyMinted;
    mapping(bytes32 => uint256[]) private s_tokensOfEmail;
    mapping(uint256 => bool) private s_isTokenClaimed;
    uint256 private s_nextTokenId;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    /*
     * - NvtMinted:  voucher mintado em escrow. Sustenta o indexador off-chain (tokenId, paymentKey, emailHash, uri).
     * - NvtClaimed: voucher resgatado — posse transferida do escrow ao cliente.
     * - NvtRescued: token travado resgatado por emergência (admin/multisig).
     */
    event NvtMinted(uint256 indexed tokenId, bytes32 indexed paymentKey, bytes32 indexed emailHash, string uri);
    event NvtClaimed(uint256 indexed tokenId, address indexed to);
    event NvtRescued(uint256 indexed tokenId, address indexed to);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    /*
     * Define nome/símbolo do ERC-721 e concede o papel de admin ao multisig da Nautt.
     * O admin concede MINTER_ROLE e OPERATOR_ROLE posteriormente.
     */
    /// @param admin endereço do multisig que administra roles, pause e rescue.
    constructor(address admin) ERC721("Nautt Voucher Token", "NVT") {
        if (admin == address(0)) {
            revert ZeroAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /*
     * - mint:   MINTER_ROLE, whenNotPaused. Idempotente por paymentKey. Minta em escrow (address(this)).
     * - claim:  OPERATOR_ROLE, whenNotPaused, nonReentrant. Transfere a posse ao cliente uma única vez (CEI).
     * - pause / unpause: DEFAULT_ADMIN_ROLE. Parada de emergência que cobre mint e claim.
     * - rescue: DEFAULT_ADMIN_ROLE. Saída de emergência para tokens travados no escrow (evento auditável).
     * - onERC721Received: obrigatório — o mint via _safeMint(address(this)) invoca este hook no contrato.
     * mint/claim/rescue estão como stub revertendo NotImplemented() até serem implementados passo a passo.
     */

    /// @notice Minta um NVT em escrow após a confirmação de um pagamento.
    /// @dev TODO: Checks (idempotência) → Effects (mappings, _setTokenURI) → Interactions (_safeMint). Emitir NvtMinted.
    /// @param paymentKey chave determinística do pagamento (keccak256(paymentId)).
    /// @param emailHash hash salgada do email do cliente, calculada off-chain.
    /// @param uri referência dos metadados off-chain (S3).
    /// @return tokenId identificador do token criado.
    function mint(bytes32 paymentKey, bytes32 emailHash, string calldata uri)
        external
        onlyRole(MINTER_ROLE)
        whenNotPaused
        returns (uint256 tokenId)
    {
        revert NotImplemented();
    }

    /// @notice Resgata um voucher transferindo sua posse do escrow para o cliente (uma única vez).
    /// @dev TODO: seguir CEI — marcar s_isTokenClaimed = true ANTES do _safeTransfer. Emitir NvtClaimed.
    /// @param tokenId identificador do token a resgatar.
    /// @param to endereço da carteira do cliente informado no front-end.
    function claim(uint256 tokenId, address to) external onlyRole(OPERATOR_ROLE) whenNotPaused nonReentrant {
        revert NotImplemented();
    }

    /// @notice Pausa mint e claim (parada de emergência).
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Retoma as operações após uma pausa.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Saída de emergência para tokens travados no escrow. Somente via admin/multisig.
    /// @dev TODO: transferir o token de address(this) para `to` e emitir NvtRescued.
    /// @param tokenId identificador do token a resgatar por emergência.
    /// @param to endereço de destino.
    function rescue(uint256 tokenId, address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        revert NotImplemented();
    }

    /// @inheritdoc IERC721Receiver
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /*
     * API pública de leitura — nomes limpos que expõem o storage privado s_:
     * - tokensOf:        emailHash => tokenIds do cliente (consulta central do resgate).
     * - mintedPaymentOf: paymentKey => tokenId gerado.
     * - isTokenClaimed:  tokenId => já resgatado?
     * - supportsInterface: override combinando ERC721URIStorage + AccessControl (exigência da OZ v5).
     */

    /// @notice Lista os tokenIds vinculados a um email (via hash salgada).
    /// @param emailHash hash salgada do email do cliente.
    /// @return a lista de tokenIds do cliente.
    function tokensOf(bytes32 emailHash) external view returns (uint256[] memory) {
        return s_tokensOfEmail[emailHash];
    }

    /// @notice Retorna o tokenId gerado por um pagamento.
    /// @param paymentKey chave do pagamento (keccak256(paymentId)).
    /// @return o tokenId associado (0 se não houver — confira com o fluxo de idempotência).
    function mintedPaymentOf(bytes32 paymentKey) external view returns (uint256) {
        return s_mintedPayments[paymentKey];
    }

    /// @notice Indica se um token já foi resgatado.
    /// @param tokenId identificador do token.
    /// @return true se já resgatado, false se ainda em escrow.
    function isTokenClaimed(uint256 tokenId) external view returns (bool) {
        return s_isTokenClaimed[tokenId];
    }

    /// @inheritdoc ERC721URIStorage
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721URIStorage, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
