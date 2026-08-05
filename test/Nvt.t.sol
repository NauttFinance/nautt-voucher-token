// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Nvt, InvalidPaymentKey, InvalidEmailHash, InvalidURI, PaymentAlreadyMinted, TokenAlreadyClaimed, ZeroAddress} from "../src/Nvt.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract NvtTest is Test {
    /*//////////////////////////////////////////////////////////////
                             SETUP & STATE
    //////////////////////////////////////////////////////////////*/
    Nvt public nvt; // Storage do contrato

    // Fake addresses
    address public USER = makeAddr("USER");
    address public OPERATOR = makeAddr("OPERATOR"); // lambda
    address public MINTER = makeAddr("MINTER"); // backend
    address public WALLET_ADMIN = makeAddr("DEFAULT_ADMIN"); // wallet multisig
    address public RECOVERY_VAULT = makeAddr("RECOVERY_VAULT"); // vault secundária
    bytes32 public PAYMENT_KEY = keccak256("PAYMENT_KEY");
    bytes32 public PAYMENT_KEY2 = keccak256("PAYMENT_KEY2");
    bytes32 public EMAIL_HASH = keccak256("EMAIL_HASH");
    string public URI = "https://example.com/metadata.json";

    /// @notice Roda antes de cada teste: faz o deploy do Nvt e concede MINTER_ROLE e OPERATOR_ROLE.
    function setUp() external {
        // 1. Deploy — WALLET_ADMIN recebe o DEFAULT_ADMIN_ROLE; RECOVERY_VAULT é fixado no constructor.
        nvt = new Nvt(WALLET_ADMIN, RECOVERY_VAULT);

        // 2. Só quem tem DEFAULT_ADMIN_ROLE concede roles → "viramos" o WALLET_ADMIN pra conceder.
        vm.startPrank(WALLET_ADMIN);
        nvt.grantRole(nvt.MINTER_ROLE(), MINTER);
        nvt.grantRole(nvt.OPERATOR_ROLE(), OPERATOR);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                  MINT
    //////////////////////////////////////////////////////////////*/

    /// @notice Caminho feliz: um MINTER minta e o token nasce em escrow (dono = contrato),
    ///         com tokenURI, mapping pagamento→token e estado "não resgatado" corretos.
    function testMinterCanMintAndContractReceivesToken() public {
        // Arrange
        vm.startPrank(MINTER);

        // Act
        uint256 tokenId = nvt.mint(PAYMENT_KEY, EMAIL_HASH, URI);
        vm.stopPrank();

        // Assert
        assertEq(tokenId, 0); // primeiro token é 0
        assertEq(nvt.ownerOf(tokenId), address(nvt)); // escrow
        assertEq(nvt.balanceOf(address(nvt)), 1);
        assertEq(nvt.tokenURI(tokenId), URI); // metadados — assertEq de string direto!
        assertEq(nvt.mintedPaymentOf(PAYMENT_KEY), tokenId); // pagamento -> token
        assertFalse(nvt.isTokenClaimed(tokenId)); // afirma que o token ainda não foi reivindicado
    }

    /// @notice Separação de papéis: quem tem OPERATOR_ROLE (mas não MINTER_ROLE) não consegue mintar.
    function testOperatorCannotMint() public {
        // Arrange
        bytes32 minterRole = nvt.MINTER_ROLE(); // ⚠️ resolver ANTES do prank

        // Act & Assert — operador não pode mintar
        vm.prank(OPERATOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                OPERATOR, // quem tentou
                minterRole // qual papel faltava
            )
        );
        nvt.mint(PAYMENT_KEY, EMAIL_HASH, URI);
    }

    /// @notice Controle de acesso: um endereço sem nenhuma role não consegue mintar.
    function testNoRoleCannotMint() public {
        // Arrange
        bytes32 minterRole = nvt.MINTER_ROLE(); // ⚠️ resolver ANTES do prank

        // Act & Assert
        vm.prank(makeAddr("NO_ROLE"));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                makeAddr("NO_ROLE"), // quem tentou
                minterRole // qual papel faltava
            )
        );
        nvt.mint(PAYMENT_KEY, EMAIL_HASH, URI);
    }

    /// @notice Rejeita mint com paymentKey vazia (bytes32(0)).
    function testInvalidPaymentKey() public {
        // Arrange
        vm.startPrank(MINTER);

        // Act & Assert
        vm.expectRevert(abi.encodeWithSelector(InvalidPaymentKey.selector));
        nvt.mint(bytes32(0), EMAIL_HASH, URI);
        vm.stopPrank();
    }

    /// @notice Rejeita mint com emailHash vazia (bytes32(0)).
    function testInvalidEmailHash() public {
        // Arrange
        vm.startPrank(MINTER);

        // Act & Assert
        vm.expectRevert(abi.encodeWithSelector(InvalidEmailHash.selector));
        nvt.mint(PAYMENT_KEY, bytes32(0), URI);
        vm.stopPrank();
    }

    /// @notice Rejeita mint com uri vazia.
    function testInvalidURI() public {
        // Arrange
        vm.startPrank(MINTER);

        // Act & Assert
        vm.expectRevert(abi.encodeWithSelector(InvalidURI.selector));
        nvt.mint(PAYMENT_KEY, EMAIL_HASH, "");
        vm.stopPrank();
    }

    /// @notice Idempotência: mintar duas vezes o mesmo paymentKey reverte (garante 1 pagamento = 1 NVT).
    function testPaymentAlreadyMinted() public {
        // Arrange
        vm.startPrank(MINTER);
        nvt.mint(PAYMENT_KEY, EMAIL_HASH, URI);
        // Act & Assert
        vm.expectRevert(
            abi.encodeWithSelector(PaymentAlreadyMinted.selector, PAYMENT_KEY)
        );
        nvt.mint(PAYMENT_KEY, EMAIL_HASH, URI);
        vm.stopPrank();
    }

    /// @notice Circuit breaker: com o contrato pausado, nem o MINTER consegue mintar.
    function testMintNotWorkingWhenPaused() public {
        // Arrange
        vm.startPrank(WALLET_ADMIN);
        nvt.pause();
        vm.stopPrank();

        // Act & Assert
        vm.startPrank(MINTER);
        vm.expectRevert(
            abi.encodeWithSelector(Pausable.EnforcedPause.selector)
        );
        nvt.mint(PAYMENT_KEY, EMAIL_HASH, URI);
        vm.stopPrank();
    }

    /// @notice Cada pagamento distinto gera um tokenId único e sequencial (0, depois 1).
    function testMintIncrementsTokenId() public {
        // Arrange
        vm.startPrank(MINTER);

        // Act — capturamos o retorno de cada mint (o tokenId real gerado)
        uint256 firstId = nvt.mint(PAYMENT_KEY, EMAIL_HASH, URI);
        uint256 secondId = nvt.mint(PAYMENT_KEY2, EMAIL_HASH, URI);
        vm.stopPrank();

        // Assert
        console.log(firstId);
        console.log(secondId);
        assertEq(firstId, 0); // primeiro token é 0
        assertEq(secondId, 1); // segundo incrementou para 1
        assertEq(nvt.mintedPaymentOf(PAYMENT_KEY), firstId); // mapping pagamento -> token
        assertEq(nvt.mintedPaymentOf(PAYMENT_KEY2), secondId);
    }

    /// @notice tokensOf acumula todos os tokens de um mesmo email (via hash) e não vaza para outros.
    function testTokensOfGroupsByEmail() public {
        // Arrange
        vm.startPrank(MINTER);
        nvt.mint(PAYMENT_KEY, EMAIL_HASH, URI);
        nvt.mint(PAYMENT_KEY2, EMAIL_HASH, URI);
        vm.stopPrank();

        // Act
        uint256[] memory tokens = nvt.tokensOf(EMAIL_HASH);

        // Assert
        assertEq(tokens.length, 2);
        console.log(tokens.length);
        assertEq(tokens[0], 0);
        assertEq(tokens[1], 1);
    }

    /// @notice O mint emite NvtMinted com tokenId, paymentKey, emailHash e uri corretos.
    function testNvtMintedEvent() public {
        // Arrange
        vm.startPrank(MINTER);

        // Act & Assert — o evento esperado é declarado ANTES da chamada
        vm.expectEmit(true, true, true, true, address(nvt));
        emit Nvt.NvtMinted(0, PAYMENT_KEY, EMAIL_HASH, URI);
        nvt.mint(PAYMENT_KEY, EMAIL_HASH, URI);
        vm.stopPrank();
    }

    modifier minted() {
        vm.prank(MINTER);
        nvt.mint(PAYMENT_KEY, EMAIL_HASH, URI);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                  CLAIM
    //////////////////////////////////////////////////////////////*/

    /// @notice Só o OPERATOR resgata: qualquer outro chamador (sem role ou com role errada) reverte.
    function testNonOperatorCannotClaim() public minted {
        bytes32 operatorRole = nvt.OPERATOR_ROLE();

        address[2] memory callers = [USER, MINTER]; // sem role / com role errada
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector,
                    callers[i], // quem tentou
                    operatorRole // papel que faltou
                )
            );
            nvt.claim(0, USER);
        }
    }

    /// @notice Happy path do resgate: o OPERATOR transfere o token do escrow pro USER e marca como resgatado.
    function testOperatorCanClaimToClient() public minted {
        // Arrange
        vm.prank(OPERATOR);

        // Act
        nvt.claim(0, USER);
       
        // Assert
        assertEq(nvt.ownerOf(0), USER); // o token foi transferido para o USER
        assertTrue(nvt.isTokenClaimed(0)); // o token foi marcado como resgatado
    }

    /// @notice Rejeita resgate para o endereço zero (ZeroAddress).
    function testZeroAddressCannotClaim() public minted {
        // Arrange
        vm.prank(OPERATOR);

        // Act & Assert
        vm.expectRevert(ZeroAddress.selector);
        nvt.claim(0, address(0));
    }

    /// @notice Rejeita resgate de um token já resgatado (TokenAlreadyClaimed).
    function testTokenAlreadyClaimed() public minted {
        // Arrange
        vm.startPrank(OPERATOR);
        nvt.claim(0, USER);

        // Act & Assert
        vm.expectRevert(abi.encodeWithSelector(TokenAlreadyClaimed.selector, 0));
        nvt.claim(0, USER);
        vm.stopPrank();
    }

    modifier paused() {
        vm.prank(WALLET_ADMIN);
        nvt.pause();
        _;
    }

    /// @notice Rejeita resgate quando o contrato está pausado.
    function testClaimNotWorkingWhenPaused() public minted paused {
        // Arrange
        vm.startPrank(OPERATOR);

        // Act & Assert
        vm.expectRevert(
            abi.encodeWithSelector(Pausable.EnforcedPause.selector)
        );
        nvt.claim(0, USER);
        vm.stopPrank();
    }
}