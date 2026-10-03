# InfluenceVest

**A marketplace that lets investors fund individual content creators against enforceable, on-chain repayment terms — matched by brand fit, not cold outreach.**

---

## The problem

The creator economy has a capital access problem on both sides.

Creators with proven audiences and strong brand identities often can't grow past a ceiling — better equipment, a small team, higher production quality — because they don't fit traditional financing. They aren't businesses with balance sheets a bank can underwrite, and they're too early for most brand-sponsorship revenue to be predictable.

Investors, meanwhile, have no structured way to put capital behind an individual creator. Informal deals ("I'll send you $5K, pay me back when you can") have no enforcement mechanism and no way to find creators who actually match the investor's audience or brand.

InfluenceVest solves both sides at once: a structured way for creators to raise capital from investors who match their brand identity, and enforceable, transparent repayment terms backed by on-chain escrow instead of trust.

## Who it's for

- **Creators** in the 10K–500K follower range — large enough to have a real, analyzable content identity and engagement history, too small to be a priority for traditional brand-deal pipelines or talent agencies.
- **Investors** looking for an alternative, creator-level asset class outside public equity or credit — individuals or small funds who want exposure to a specific audience or content niche, not just a diversified index.

## How it works

1. A creator connects their Instagram account. The platform pulls their recent posts and builds a brand profile automatically — content category, aesthetic, audience type, tone, production quality — rather than asking the creator to self-describe (self-reported brand identity is unreliable and hard to compare across creators).
2. An investor sets their own brand-fit preferences. The platform scores every creator against those preferences (0–100) and surfaces the best matches, adjusted for the creator's actual engagement rate — so a creator with a large but disengaged audience doesn't rank above a smaller, highly engaged one.
3. Investor and creator agree on terms (principal, return amount, repayment window). The platform deploys a smart contract that escrows the investor's funds, releases them to the creator on acceptance, and enforces repayment on-chain — no handshake, no relying on either side's word.

---

## Key product decisions

### Removing the wallet barrier, at the cost of platform custody risk
Requiring investors to have MetaMask and sign their own transactions would filter out most first-time, non-crypto-native investors before they ever fund a deal — exactly the audience this product needs to reach to prove the model works. Instead, the platform's own wallet signs contract deployments. The trade-off is real: the platform now holds a deployer private key and pays gas on investors' behalf. The blast radius is deliberately limited — that wallet only ever holds MATIC for gas, never investor USDC, so a compromised deployer key can't touch user funds directly.

### A fixed brand taxonomy, not open-ended AI descriptions
It would be easy to let the vision model generate rich, free-text descriptions of a creator's brand ("warm minimalist aesthetic with sustainability undertones"). It would also make creators impossible to compare or filter against each other — you can't query or rank free text. Classification instead runs against a fixed taxonomy (15 content categories, 10 aesthetic styles, plus audience type, tone, and production quality), which costs some descriptive richness in exchange for every creator being directly comparable and filterable, which is the actual product requirement: investors need to search and rank, not read prose.

### Shipping image-only brand analysis first, deferring video
Reels carry real brand signal — speaking tone, edit pace, content structure — that static images miss entirely. Analyzing them properly means frame extraction plus a vision or multimodal model run per frame, which multiplies inference cost well beyond the per-image classification used today. Rather than delay launch to cover every content format, v1 scopes to image posts only, at roughly $0.15 per creator profile build. Video analysis is scoped as a defined next capability (a separate microservice returning the same output schema, so nothing downstream has to change when it ships) rather than an open-ended "someday" — see Roadmap below.

### Polling the blockchain instead of building event-driven infrastructure
Real-time event listeners (WebSockets, webhook infrastructure) are the "correct" way to track on-chain state changes, but they're meaningfully more infrastructure to build and operate. At current (testnet, low-volume) scale, polling active contracts every two minutes is simpler to build, easier to debug, and costs nothing in user-facing latency that matters at this stage. This is explicitly a decision to defer infrastructure investment until deal volume justifies it, not a belief that polling is the right long-term architecture.

### One shared type system across every service
`DealRecord`, `InfluencerRecord`, `PostAnalysis`, and every notification payload are defined once and imported everywhere — the OAuth service, the brand pipeline, the contract facilitator, and the frontend all consume the same types. This isn't just code hygiene: it directly caught a real bug during development, where `DealRecord` was missing its `id` field, which would have silently generated broken `/deals/undefined/fund` URLs in production notification emails. A shared type system turns an entire category of integration bug into a compile-time error instead of a support ticket.

## What success looks like

The metric that matters most in the first phase is **funded-deal conversion rate** — the share of initiated deals (investor and creator agree on terms) that actually reach the Funded state. A low conversion rate here means the matching or terms-negotiation experience is broken before the product even gets to test whether repayment works. Supporting metrics worth tracking alongside it:

- **Profile-to-match rate** — of creators who connect Instagram, how many get surfaced as a strong match (fit score above some threshold) to at least one investor. A creator base nobody gets matched to is a dead inventory problem.
- **Repayment completion rate** — of funded deals, how many reach Complete rather than running overdue. This is the real test of whether the underlying financial product (not just the matching UX) works.
- **Investor repeat-investment rate** — whether an investor who funds one deal comes back to fund another. This is the clearest signal of trust in the enforcement mechanism actually working as promised.

## Roadmap — what I'd prioritize next, and why

1. **Video (Reels) brand analysis** — the single biggest gap in matching quality today, since a large share of creator content and personality lives in video, not static posts. Scoped already as a drop-in microservice (same output schema as the image pipeline) specifically so this doesn't require touching any downstream consumer.
2. **Persistent data layer (Postgres)** — see `database/schema.sql` in this repo. Both in-memory stores (`tokenStore.ts`, `facilitator.ts`) were deliberately written with function signatures that don't change when the backing store does, so this is a swap, not a rewrite.
3. **Event-driven contract monitoring** — replace polling with Alchemy Webhooks once deal volume makes two-minute polling latency a real user-facing problem rather than a theoretical one.
4. **Smart contract audit** — non-negotiable before any real money touches these contracts; immutability means a bug shipped is a bug permanent. This is sequenced deliberately *after* product-market signal, not before, since an audit is expensive and the contract logic may still change based on what the matching/repayment data shows.
5. **Public Meta App Review** — unlocks the OAuth flow for creators beyond manually-added testers; a 4–6 week process worth starting early once the core loop (match → deal → repay) is validated with a test cohort.

---
---

# Technical Appendix

*(Everything below this line was previously the entire README — kept in full for anyone evaluating the implementation directly.)*

## Architecture

Three decoupled TypeScript microservices with distinct responsibilities, coordinated through a shared type system and a React frontend.

```
┌─────────────────────────────────────────────────────────────────┐
│                        React Frontend                           │
│          Brand profile setup · Creator browse · Deal flow       │
└───────────────┬─────────────────────┬───────────────────────────┘
                │                     │
                ▼                     ▼
┌──────────────────────┐   ┌──────────────────────┐
│    OAuth Service     │   │  Contract Facilitator │
│      port 3000       │   │      port 4000        │
│                      │   │                       │
│  Meta OAuth 2.0 flow │   │  Deploys Solidity     │
│  Token encryption    │   │  contracts to Polygon │
│  24h refresh job     │   │  Polls deal state     │
│                      │   │  Email notifications  │
└──────────┬───────────┘   └──────────┬────────────┘
           │                          │
           ▼                          ▼
┌──────────────────────┐   ┌──────────────────────┐
│   Brand Pipeline     │   │  Polygon Amoy         │
│                      │   │  (testnet)            │
│  Instagram Graph API │   │                       │
│  Claude vision API   │   │  InvestmentBase.sol   │
│  Brand classification│   │  FixedReturnTimeLock  │
│  Fit scoring 0–100   │   │  .sol                 │
└──────────────────────┘   └──────────────────────┘
```

### OAuth Service
Handles Instagram Business account authentication via Meta's OAuth 2.0 flow. When a creator signs up, they connect their Instagram account. The service exchanges authorization codes for long-lived access tokens, stores them AES-256 encrypted, and runs a 24-hour refresh scheduler to keep tokens alive without requiring creators to re-authenticate.

### Brand Pipeline
The matching engine. Pulls the creator's last 12 image posts from the Instagram Graph API and runs each through Claude's vision model with a structured prompt against a fixed 15-category taxonomy covering content category, aesthetic style, audience type, tone, and production quality. Individual post analyses are aggregated via weighted frequency counting — weighted by per-image confidence scores — into a single brand profile. A 0–100 fit score compares business owner attributes against each creator's derived profile, adjusted by the creator's engagement rate.

### Contract Facilitator
The transaction layer. When both parties agree on terms, the facilitator deploys a `FixedReturnTimeLock` contract to Polygon using the platform's backend wallet. The contract holds investor USDC in escrow, releases to the creator on acceptance, and enforces repayment. The facilitator polls active contracts every two minutes for state changes and fires typed email notifications on each transition. The blockchain is the source of truth; the platform's database mirrors its state.

---

## Smart contract design

Two Solidity contracts compiled at runtime via the bundled `solc` binary.

`InvestmentBase` is an abstract contract implementing the shared lifecycle:
- `fund()` — investor deposits USDC; requires prior `approve()` call on the USDC token contract
- `accept()` — creator accepts terms before the acceptance deadline, activating the deal
- `reclaim()` — investor retrieves funds if the creator never accepts past the deadline

`FixedReturnTimeLock` inherits from the base and adds repayment logic:
- `repay(uint256 amount)` — creator repays in one or more installments
- `withdraw()` — investor withdraws once full repayment has landed
- `isOverdue()` — view function returning whether the lock period has passed without full repayment
- `amountOwed()` — remaining balance the creator still owes

USDC transfers use `transferFrom` rather than native ETH, which means investors must `approve()` the contract before funding — a two-step wallet interaction the frontend stepper makes explicit.

**Contract status flow:**
```
Draft → Funded → Active → Complete
                        ↘ Refunded   (investor reclaims after deadline)
```

---

## Database schema

`database/schema.sql` contains the full PostgreSQL schema designed to replace the current in-memory `Map` stores in `tokenStore.ts` and `facilitator.ts`. Key tables:

| Table | Replaces / backs |
|---|---|
| `users`, `investor_profiles`, `creator_profiles` | Base identity for both sides of the marketplace |
| `instagram_tokens` | `tokenStore.ts`'s in-memory encrypted token Map |
| `posts`, `post_analyses` | Raw Instagram post pulls and per-post Claude vision output |
| `taxonomy_values` | The fixed 15-category / 10-aesthetic-type taxonomy, as data rather than hardcoded strings |
| `brand_profiles` | The weighted-frequency aggregated brand profile per creator |
| `fit_scores` | Cached investor–creator 0–100 match scores |
| `deals`, `repayments` | `facilitator.ts`'s in-memory deal Map, plus installment-level repayment tracking the current Map doesn't capture |
| `notifications` | A durable log of every typed email notification fired, for debugging and audit |

See the file itself for full column definitions, constraints, and indexing rationale.

---

## Tech stack

| Layer                | Technology                                 |
| -------------------- | ------------------------------------------ |
| Frontend             | React 18, TypeScript 5, ethers.js 6        |
| OAuth service        | Node.js, Express, TypeScript, crypto-js    |
| Brand pipeline       | Node.js, TypeScript, Claude API (vision)   |
| Contract facilitator | Node.js, Express, TypeScript, ethers.js    |
| Smart contracts      | Solidity 0.8.24, solc (bundled)            |
| Blockchain           | Polygon Amoy testnet → Polygon mainnet     |
| Stablecoin           | USDC (ERC-20, Circle)                      |
| Instagram data       | Instagram Graph API, Meta OAuth 2.0        |
| Email                | nodemailer (Ethereal in dev, SMTP in prod) |
| Database             | PostgreSQL (schema in `database/schema.sql`) |
| Containerisation     | Docker Compose                             |

---

## Project structure

```
influencevest/
├── database/
│   └── schema.sql        # PostgreSQL schema (see Database schema above)
│
├── oauth-flow/
│   ├── src/
│   │   ├── types.ts          # Shared type definitions
│   │   ├── tokenStore.ts     # Encrypted token storage
│   │   ├── oauthHandler.ts   # Four-step OAuth flow
│   │   └── server.ts         # Express routes
│   └── tsconfig.json
│
├── brand-pipeline/
│   ├── src/
│   │   ├── types.ts          # Shared type definitions
│   │   ├── instagramClient.ts # Graph API calls
│   │   ├── brandAnalyzer.ts  # Vision classification + scoring
│   │   └── pipeline.ts       # Orchestrator
│   └── tsconfig.json
│
├── contract-facilitator/
│   ├── src/
│   │   ├── types.ts          # Shared type definitions
│   │   ├── contracts/
│   │   │   ├── InvestmentBase.sol
│   │   │   └── FixedReturnTimeLock.sol
│   │   ├── compiler.ts       # Runtime Solidity compilation
│   │   ├── chain.ts          # ethers.js provider + wallet
│   │   ├── notifications.ts  # Typed email templates
│   │   ├── facilitator.ts    # Deploy, poll, notify
│   │   └── server.ts         # REST API
│   └── tsconfig.json
│
├── frontend/
│   └── src/
│       └── App.tsx           # React SPA — profile, browse, deal flow
│
└── docker-compose.yml
```

---

## Local setup

**Prerequisites:** Node.js 18+, Docker, a Meta developer account, an Alchemy account (Polygon Amoy), an Anthropic API key, a PostgreSQL instance, and a fresh Ethereum wallet funded with test MATIC.

```
# Clone and install dependencies
git clone <repo>

cd oauth-flow && npm install
cd ../brand-pipeline && npm install
cd ../contract-facilitator && npm install
cd ../frontend && npm install

# Set up the database
psql -U <user> -d <database> -f database/schema.sql

# Configure environment variables
cp oauth-flow/.env.example oauth-flow/.env
cp brand-pipeline/.env.example brand-pipeline/.env
cp contract-facilitator/.env.example contract-facilitator/.env
# Fill in each .env file — see comments in each file for where to get each value,
# including DATABASE_URL for the Postgres instance you just set up

# Type-check all services
cd oauth-flow && npx tsc --noEmit
cd ../brand-pipeline && npx tsc --noEmit
cd ../contract-facilitator && npx tsc --noEmit

# Run all services via Docker Compose
docker-compose up

# Or run individually in development mode
cd oauth-flow && npx ts-node src/server.ts          # port 3000
cd brand-pipeline && npx ts-node src/pipeline.ts    # runs once with INSTAGRAM_ACCESS_TOKEN
cd contract-facilitator && npx ts-node src/server.ts # port 4000
```

**Testing the contract facilitator:**

```
curl -X POST http://localhost:4000/deals \
  -H "Content-Type: application/json" \
  -d '{
    "dealId": "deal_001",
    "investorAddress": "0xYourInvestorAddress",
    "investeeAddress": "0xYourCreatorAddress",
    "principalUSDC": 1000,
    "returnAmountUSDC": 1100,
    "lockDays": 90,
    "acceptanceDays": 7,
    "investorEmail": "investor@example.com",
    "influencerEmail": "creator@example.com",
    "influencerUsername": "testcreator",
    "investorName": "Test Investor"
  }'
```

The response includes the deployed contract address and a Polygonscan explorer link.

---

## Generating a deployer wallet

```
node -e "const {ethers} = require('ethers'); const w = ethers.Wallet.createRandom(); console.log('Address:', w.address); console.log('Private key:', w.privateKey)"
```

Fund the address with test MATIC from [faucet.polygon.technology](https://faucet.polygon.technology) (select Amoy network). Fund a second wallet with test USDC from [faucet.circle.com](https://faucet.circle.com).

The deployer wallet signs contract deployments and pays gas only. It never holds investor USDC.
