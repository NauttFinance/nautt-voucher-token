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
 * - InvalidEmailHash:     rejeita emailHash zerada (bytes32(0)) no mint.
 * - InvalidPaymentKey:    rejeita paymentKey zerada (bytes32(0)) no mint.
 * - InvalidURI:           rejeita uri vazia no mint.
 * - ZeroAddress:          rejeita o endereço zero em entradas obrigatórias.
 */
error PaymentAlreadyMinted(bytes32 paymentKey);
error TokenAlreadyClaimed(uint256 tokenId);
error InvalidEmailHash();
error InvalidPaymentKey();
error InvalidURI();
error ZeroAddress();

/**
 * @title Nvt — Nautt Voucher Token
 * @notice Comprovante de pagamento (voucher) no padrão ERC-721 na Polygon. Registra que um cliente
 *         final pagou no cartão da Nautt e recebeu o produto/serviço — uma escrituração descentralizada.
 * @dev Modelo de escrow: o token é mintado para `address(this)` e custodiado pelo próprio contrato
 *      até o resgate (`claim`), quando a posse é transferida ao cliente uma única vez. Mint e claim
 *      são sempre executados pelo backend da Nautt (relayer); o cliente nunca assina nem paga gas.
 *      Nenhuma PII on-chain: o vínculo com o cliente é uma hash salgada do email calculada off-chain.
 */
contract Nvt is
    ERC721URIStorage,
    AccessControl,
    Pausable,
    ReentrancyGuard,
    IERC721Receiver
{
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
     *
     * Imutáveis (prefixo i_; definidos no constructor, nunca alterados):
     * - i_recoveryVault: destino fixo do rescue. O rescue nunca envia para endereço arbitrário — só para este cofre,
     *                    respeitando least privilege (o admin não pode "mandar qualquer NFT pra qualquer lugar").
     */
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    mapping(bytes32 => uint256) private s_mintedPayments;
    mapping(bytes32 => bool) private s_paymentAlreadyMinted;
    mapping(bytes32 => uint256[]) private s_tokensOfEmail;
    mapping(uint256 => bool) private s_isTokenClaimed;
    uint256 private s_nextTokenId;

    address private immutable i_recoveryVault;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    /*
     * - NvtMinted:  voucher mintado em escrow. Sustenta o indexador off-chain (tokenId, paymentKey, emailHash, uri).
     * - NvtClaimed: voucher resgatado — posse transferida do escrow ao cliente.
     * - NvtRescued: token travado resgatado por emergência (admin/multisig).
     */
    event NvtMinted(
        uint256 indexed tokenId,
        bytes32 indexed paymentKey,
        bytes32 indexed emailHash,
        string uri
    );
    event NvtClaimed(uint256 indexed tokenId, address indexed to);
    event NvtRescued(uint256 indexed tokenId, address indexed to);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    /*
     * Define nome/símbolo do ERC-721, concede o papel de admin ao multisig da Nautt e fixa o cofre de recuperação.
     * O admin concede MINTER_ROLE e OPERATOR_ROLE posteriormente. O cofre (i_recoveryVault) é imutável: destino
     * único de qualquer rescue.
     */
    /// @param admin endereço do multisig que administra roles, pause e rescue.
    /// @param recoveryVault endereço fixo para onde o rescue envia tokens de emergência (imutável).
    constructor(
        address admin,
        address recoveryVault
    ) ERC721("Nautt Voucher Token", "NVT") {
        if (admin == address(0) || recoveryVault == address(0)) {
            revert ZeroAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        i_recoveryVault = recoveryVault;
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /*
     * - mint:   MINTER_ROLE, whenNotPaused. Idempotente por paymentKey. Minta em escrow (address(this)).
     * - claim:  OPERATOR_ROLE, whenNotPaused, nonReentrant. Transfere a posse ao cliente uma única vez (CEI).
     * - pause / unpause: DEFAULT_ADMIN_ROLE. Parada de emergência que cobre mint e claim.
     * - rescue: DEFAULT_ADMIN_ROLE, nonReentrant. Saída de emergência: envia o token do escrow para o cofre fixo
     *           (i_recoveryVault). Sem whenNotPaused — precisa funcionar durante uma pausa. Evento auditável.
     * - onERC721Received: obrigatório — o mint via _safeMint(address(this)) invoca este hook no contrato.
     */

    /// @notice Minta um NVT em escrow após a confirmação de um pagamento.
    /// @dev TODO: Checks (idempotência) → Effects (mappings, _setTokenURI) → Interactions (_safeMint). Emitir NvtMinted.
    /// @param paymentKey chave determinística do pagamento (keccak256(paymentId)).
    /// @param emailHash hash salgada do email do cliente, calculada off-chain.
    /// @param uri referência dos metadados off-chain (S3).
    /// @return tokenId identificador do token criado.

    function mint(
        bytes32 paymentKey,
        bytes32 emailHash,
        string calldata uri
    ) external onlyRole(MINTER_ROLE) whenNotPaused returns (uint256 tokenId) {
        // Checks
        if (paymentKey == bytes32(0)) {
            revert InvalidPaymentKey();
        }
        if (emailHash == bytes32(0)) {
            revert InvalidEmailHash();
        }
        if (bytes(uri).length == 0) {
            revert InvalidURI();
        }
        /// @dev verifica se o pagamento já foi mintado em NFT
        if (s_paymentAlreadyMinted[paymentKey]) {
            revert PaymentAlreadyMinted(paymentKey);
        }

        // Effects
        tokenId = s_nextTokenId++;
        s_paymentAlreadyMinted[paymentKey] = true;
        s_mintedPayments[paymentKey] = tokenId;
        s_tokensOfEmail[emailHash].push(tokenId);
        _setTokenURI(tokenId, uri);

        // Interactions
        _safeMint(address(this), tokenId);

        emit NvtMinted(tokenId, paymentKey, emailHash, uri);
    }

    /// @notice Resgata um voucher transferindo sua posse do escrow para o cliente (uma única vez).
    /// @dev TODO: seguir CEI — marcar s_isTokenClaimed = true ANTES do _safeTransfer. Emitir NvtClaimed.
    /// @param tokenId identificador do token a resgatar.
    /// @param to endereço da carteira do cliente informado no front-end.
    function claim(
        uint256 tokenId,
        address to
    ) external nonReentrant whenNotPaused onlyRole(OPERATOR_ROLE) {
        // Checks
        if (to == address(0)) {
            revert ZeroAddress();
        }
        if (s_isTokenClaimed[tokenId]) {
            revert TokenAlreadyClaimed(tokenId);
        }

        // Effects
        s_isTokenClaimed[tokenId] = true;

        // Interactions
        _safeTransfer(address(this), to, tokenId);

        emit NvtClaimed(tokenId, to);
    }

    /// @notice Pausa mint e claim (parada de emergência).
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Retoma as operações após uma pausa.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Saída de emergência: transfere um token travado do escrow para o cofre fixo. Somente admin/multisig.
    /// @dev Sem whenNotPaused (deve funcionar durante uma pausa). CEI: marca claimed antes de transferir. O destino
    ///      é sempre i_recoveryVault — nunca um endereço arbitrário.
    /// @param tokenId identificador do token a resgatar por emergência.
    function rescue(
        uint256 tokenId
    ) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        // Checks
        if (s_isTokenClaimed[tokenId]) {
            revert TokenAlreadyClaimed(tokenId);
        }

        // Effects
        s_isTokenClaimed[tokenId] = true;

        // Interactions
        _safeTransfer(address(this), i_recoveryVault, tokenId);

        emit NvtRescued(tokenId, i_recoveryVault);
    }

    /// @inheritdoc IERC721Receiver
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
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
    function tokensOf(
        bytes32 emailHash
    ) external view returns (uint256[] memory) {
        return s_tokensOfEmail[emailHash];
    }

    /// @notice Retorna o tokenId gerado por um pagamento.
    /// @param paymentKey chave do pagamento (keccak256(paymentId)).
    /// @return o tokenId associado (0 se não houver — confira com o fluxo de idempotência).
    function mintedPaymentOf(
        bytes32 paymentKey
    ) external view returns (uint256) {
        return s_mintedPayments[paymentKey];
    }

    /// @notice Indica se um token já foi resgatado.
    /// @param tokenId identificador do token.
    /// @return true se já resgatado, false se ainda em escrow.
    function isTokenClaimed(uint256 tokenId) external view returns (bool) {
        return s_isTokenClaimed[tokenId];
    }

    /// @inheritdoc ERC721URIStorage
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721URIStorage, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
