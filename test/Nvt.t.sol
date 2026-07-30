// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Nvt} from "../src/Nvt.sol";

contract NvtTest is Test {
    /*//////////////////////////////////////////////////////////////
                             SETUP & STATE
    //////////////////////////////////////////////////////////////*/
    Nvt public nvt; // Storage do contrato

    // Fake addresses
    address public OPERATOR = makeAddr("OPERATOR"); // lambda
    address public MINTER = makeAddr("MINTER"); // backend
    address public WALLET_ADMIN = makeAddr("ADMIN"); // wallet multisig
    address public RECOVERY_VAULT = makeAddr("RECOVERY_VAULT"); // vault secundária
    bytes32 public PAYMENT_KEY = keccak256("PAYMENT_KEY");
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
}
