# CLAUDE.md — NVT (Nautt Voucher Token)

> Contexto de projeto para agentes de IA (Cowork e Claude Code/VSCode) e desenvolvedores.
> Leia este arquivo antes de escrever ou revisar qualquer código do contrato.
> **Fonte de verdade das decisões.** Se algo aqui conflitar com um comentário no código, este arquivo vence — ou o conflito deve ser resolvido explicitamente e registrado aqui.

---

## 1. O que é o NVT

Comprovante de pagamento no padrão **NFT (ERC-721) na Polygon**. Registra que um cliente final pagou no cartão de crédito da Nautt e recebeu o produto/serviço — uma "escrituração descentralizada" do voucher.

- Mintado automaticamente pela Nautt após confirmação de pagamento, **sem ação do cliente** (não é lazy mint).
- Só o **cliente final** recebe. O merchant não recebe nada.
- No MVP é só contrafé, **sem burn** (burn é Fase 2).
- **Um NVT por pagamento.** Cliente nunca assina transação nem paga gas.

Specs completas: `NVT-01-contrato-requisitos.md`, `NVT-02-ambiente-verificacao.md`, `NVT-03-conceitual-geral.md`.

---

## 2. Stack e decisões firmadas

| Tema | Decisão |
|---|---|
| Linguagem / toolkit | Solidity + Foundry |
| Padrão | ERC-721 |
| Rede | Polygon mainnet (testnet primeiro) |
| Biblioteca base | OpenZeppelin Contracts **v5.6.1** (`lib/openzeppelin-contracts`) |
| Custódia | **Escrow no contrato** até o resgate |
| Redeem | **Transferência de posse** (do escrow para o cliente), sem burn no MVP |
| Executor | Mint e claim **sempre pelo backend da Nautt** (relayer); cliente não paga gas |
| Vínculo cliente↔NFT | **Hash salgada do email** (`keccak256(email + salt)`), salt secreto off-chain |
| PII | **Nenhuma on-chain.** Metadados off-chain em **S3**; on-chain só `tokenURI` + `emailHash` |
| Idempotência | `paymentKey = keccak256(paymentId)` como chave determinística |
| Upgradeable | **Não** no MVP |
| Enumerable | **Não usar `ERC721Enumerable`.** Lookup do cliente é por `emailHash`, não por dono (em escrow o dono é sempre o contrato). Indexação extra é off-chain via evento `NvtMinted`. |

---

## 3. Arquitetura do contrato

### Herança (OpenZeppelin v5)
`ERC721URIStorage`, `AccessControl`, `Pausable`, `ReentrancyGuard`, `IERC721Receiver`.

> **Atenção v5:** o hook de transferência é `_update()` (não os antigos `_beforeTokenTransfer`/`_afterTokenTransfer`). `supportsInterface` precisa de override combinando as bases relevantes.

### Fluxo (visão)
```
Pagamento confirmado
  → evento Kafka (fat event)
  → consumer (Lambda) monta metadados + emailHash (salgada, off-chain)
  → chama mint() [MINTER_ROLE] → _safeMint(address(this)) (escrow) + registra mappings

Cliente resgata
  → informa email na tela de redeem
  → backend calcula hash(email + salt) e consulta o contrato
  → se há NFT: envia código de confirmação ao email
  → cliente confirma código + informa endereço da carteira
  → backend [OPERATOR_ROLE] chama claim(tokenId, to)
  → contrato transfere address(this) → cliente (uma única vez)
```

### Roles
- `DEFAULT_ADMIN_ROLE` — multisig da Nautt. Concede/revoga roles, controla `pause` e `rescue`. O timelock do `rescue` é **operacional** (o admin É um Timelock/Safe), não lógica interna do contrato.
- `MINTER_ROLE` — backend que consome o evento Kafka e minta.
- `OPERATOR_ROLE` — serviço que executa o `claim` após confirmação por email.

Separar MINTER de OPERATOR: comprometer um não permite abusar do outro.

### Storage
Nomes seguem a convenção `s_` (ver §4). Storage **privado**; a API pública são views explícitas com nomes limpos.

| Var (interna) | Tipo | Papel |
|---|---|---|
| `s_mintedPayments` | `mapping(bytes32 => uint256)` | pagamento → tokenId gerado |
| `s_paymentAlreadyMinted` | `mapping(bytes32 => bool)` | pagamento já mintado? (idempotência — distingue "não existe" de "token 0") |
| `s_tokensOfEmail` | `mapping(bytes32 => uint256[])` | emailHash → lista de tokenIds do cliente |
| `s_isTokenClaimed` | `mapping(uint256 => bool)` | token já resgatado? (impede resgate duplo) |
| `s_nextTokenId` | `uint256` | contador do próximo tokenId livre |

### Funções (API)
- `mint(bytes32 paymentKey, bytes32 emailHash, string uri) → uint256` — `MINTER_ROLE`, `whenNotPaused`. Revert se já mintado. `_safeMint(address(this))` + `_setTokenURI` + registra mappings + emite `NvtMinted`.
- `claim(uint256 tokenId, address to)` — `OPERATOR_ROLE`, `whenNotPaused`, `nonReentrant`. Revert se já resgatado ou `to == address(0)`. **CEI:** marca `s_isTokenClaimed = true` **antes** de `_safeTransfer`. Emite `NvtClaimed`.
- Views: `tokensOf(bytes32 emailHash) → uint256[]`, `mintedPaymentOf(bytes32 paymentKey) → uint256`, `isTokenClaimed(uint256 tokenId) → bool`, além de `ownerOf` / `tokenURI` / `balanceOf` do ERC-721.
- Admin: `pause()` / `unpause()` (`DEFAULT_ADMIN_ROLE`); `rescue(uint256 tokenId, address to)` (`DEFAULT_ADMIN_ROLE`, evento auditável); `grantRole` / `revokeRole` (herdados).
- `onERC721Received` — obrigatório, pois o mint vai para `address(this)` via `_safeMint`.

### Eventos
```solidity
event NvtMinted(uint256 indexed tokenId, bytes32 indexed paymentKey, bytes32 indexed emailHash, string uri);
event NvtClaimed(uint256 indexed tokenId, address indexed to);
event NvtRescued(uint256 indexed tokenId, address indexed to);
```

### Erros
Usar **erros personalizados** (não `require` com string) — mais barato em gas e no padrão de nomenclatura. Ex.: `PaymentAlreadyMinted()`, `TokenAlreadyClaimed()`, `ZeroAddress()`.

---

## 4. Boas práticas OBRIGATÓRIAS

Todo código do contrato **deve** seguir os três padrões abaixo. Não são opcionais.

### 4.1 Layout do arquivo e do contrato (style guide)

Ordem do **arquivo**:
```
1. version (pragma)
2. imports
3. errors
4. interfaces, libraries, contract
```

Ordem **dentro do contrato**:
```
1. Type declarations
2. State variables
3. Events
4. Modifiers
5. Functions
```

Ordem das **funções**:
```
1. constructor
2. receive (se existir)
3. fallback (se existir)
4. external
5. public
6. internal
7. private
8. view & pure (por último, dentro de cada nível de visibilidade)
```

### 4.2 Convenções de nomenclatura

| Tipo | Convenção | Exemplo |
|---|---|---|
| Contratos / Structs / Enums / Eventos | `PascalCase` | `Nvt`, `UserInfo`, `NvtMinted` |
| Funções / Modifiers / Variáveis locais | `camelCase` | `claim()`, `whenNotPaused`, `tokenId` |
| Constantes | `UPPER_SNAKE_CASE` | `MINTER_ROLE`, `MAX_SUPPLY` |
| Variáveis de storage | `s_` + `camelCase` | `s_isTokenClaimed`, `s_nextTokenId` |
| Variáveis imutáveis | `i_` + `camelCase` | `i_owner`, `i_router` |
| Interfaces | `I` + `PascalCase` | `IERC721`, `IERC721Receiver` |
| Erros personalizados | `PascalCase` | `TokenAlreadyClaimed()` |

**Regra da API pública:** storage é `private` com prefixo `s_`; expor dados via **views explícitas** de nome limpo (`isTokenClaimed()`, `tokensOf()`) em vez de mapping `public` (o getter automático carregaria o prefixo `s_`).

### 4.3 Comentários: NatSpec nas funções + seções organizadas por banner

Padrão de documentação do contrato (organizado por seção, não linha a linha):

- **Funções e o contrato** usam **NatSpec** (`///` ou `/** ... */`) com as tags apropriadas (`@notice`, `@dev`, `@param`, `@return`, `@inheritdoc`). É onde `@param`/`@return` têm valor real para a API.
- **Seções** (errors, state variables, events, blocos de funções) são separadas por **banners** no estilo Cyfrin/Solmate e recebem **uma explicação geral** cobrindo todos os itens da seção — em vez de um comentário por declaração:

```solidity
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    /*
     * Explicação geral de todas as variáveis desta seção...
     */
```

- Banners e textos de seção usam bloco `/* ... */` **simples** (não `/** */`), para não serem interpretados como NatSpec de uma declaração específica.
- **Não** documentar cada `state variable`/`event`/`error` individualmente com NatSpec — isso vira ruído. A explicação vive no bloco da seção.

### 4.4 CEI Pattern (Checks-Effects-Interactions)

Toda função que muda estado segue estritamente:

1. **Checks** — validar permissões, entradas e pré-requisitos de estado. Reverter cedo (economiza gas).
2. **Effects** — aplicar todas as mudanças de storage **antes** de qualquer chamada externa.
3. **Interactions** — chamadas externas / transferências **por último**.

Aplicação crítica: em `claim`, marcar `s_isTokenClaimed[tokenId] = true` (Effect) **antes** de `_safeTransfer` (Interaction). `nonReentrant` é defesa em profundidade, não substitui o CEI.

---

## 5. Segurança (checklist antes de deploy)

- [ ] Roles separadas MINTER / OPERATOR / ADMIN; ADMIN é multisig.
- [ ] `rescue` só via multisig + timelock (garantia operacional do admin).
- [ ] CEI + `nonReentrant` no `claim`.
- [ ] Idempotência por `paymentKey` testada contra retry.
- [ ] `Pausable` cobrindo `mint` e `claim`.
- [ ] Nenhuma PII on-chain; `emailHash` salgada; salt fora do contrato.
- [ ] Verificação de email off-chain; salt nunca on-chain.
- [ ] `onERC721Received` implementado e testado (mint para `address(this)`).
- [ ] Testes de fuzzing (Foundry) para `mint` / `claim` / idempotência / resgate duplo.
- [ ] Erros personalizados no lugar de `require`+string.

---

## 6. Estrutura do repositório

```
src/        contratos (Nvt.sol) — o Counter.sol padrão será removido
script/     scripts de deploy Foundry
test/       testes (unit + fuzz)
lib/        dependências (submodules): forge-std, openzeppelin-contracts
```

Remapping necessário (`remappings.txt` ou auto pelo forge):
```
@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
forge-std/=lib/forge-std/src/
```

---

## 7. Regras de trabalho

- **Não rodar `forge build`/`forge test`/deploy sem solicitação explícita** do Gabriel.
- Trabalhar em passo a passo; confirmar antes de ações que alteram o repositório.
- Fase 2 (burn, gamificação/loyalty, marketplace) está **fora do escopo** — não implementar nem assumir.
- Se o burn da Fase 2 exigir mudança no contrato, decidir entre novo contrato ou proxy **antes** — registrar aqui.

---

## 8. Estado atual

- [x] Scaffold Foundry criado (com `Counter.sol` padrão, **ainda a remover**).
- [x] OpenZeppelin v5.6.1 instalado (`lib/openzeppelin-contracts`) + `remappings.txt`.
- [x] Esqueleto do `Nvt.sol` (estrutura + partes estruturais implementadas; `mint`/`claim`/`rescue` como stub `NotImplemented()`).
- [ ] Implementação de `mint` / `claim` / `rescue` (remover `NotImplemented()`).
- [ ] Remover `Counter.sol` / `Counter.s.sol` / `Counter.t.sol`.
- [ ] Testes (unit + fuzz).
- [ ] Script de deploy.

_Atualizar esta seção a cada passo concluído._
