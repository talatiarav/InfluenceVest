-- ============================================================================
-- InfluenceVest — PostgreSQL schema
-- ============================================================================
-- Replaces the in-memory Map stores in tokenStore.ts (oauth-flow) and
-- facilitator.ts (contract-facilitator). Per the README's own design note,
-- both services' function signatures were written so that swapping the
-- backing store for Postgres requires no changes to callers — this schema
-- is that swap.
--
-- Organized by which service/feature each table group backs:
--   1. Identity           — users, investor_profiles, creator_profiles
--   2. OAuth Service       — instagram_tokens
--   3. Brand Pipeline      — taxonomy_values, posts, post_analyses,
--                            brand_profiles, fit_scores
--   4. Contract Facilitator — deals, repayments, notifications
--
-- Run with: psql -U <user> -d <database> -f database/schema.sql
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;  -- for gen_random_uuid()

-- ============================================================================
-- 1. IDENTITY
-- ============================================================================

CREATE TABLE users (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email         TEXT NOT NULL UNIQUE,
    display_name  TEXT,
    wallet_address TEXT,                    -- on-chain address, once known
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Table-per-role extension tables: every investor/creator is a user,
-- with role-specific columns kept out of the shared users table.

CREATE TABLE investor_profiles (
    user_id          UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    -- Business-owner brand-fit preferences this investor is matched against.
    -- Kept as JSONB rather than fixed columns so preference dimensions can
    -- evolve alongside the brand taxonomy without a migration.
    brand_preferences JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE creator_profiles (
    user_id                  UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    instagram_username       TEXT NOT NULL UNIQUE,
    instagram_user_id        TEXT NOT NULL UNIQUE,  -- Instagram's own numeric account ID
    follower_count           INTEGER,
    engagement_rate          NUMERIC(6,4),           -- e.g. 0.0325 = 3.25%
    last_profile_refresh_at  TIMESTAMPTZ,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================================
-- 2. OAUTH SERVICE  (replaces tokenStore.ts's in-memory Map)
-- ============================================================================

CREATE TABLE instagram_tokens (
    creator_id              UUID PRIMARY KEY REFERENCES creator_profiles(user_id) ON DELETE CASCADE,
    encrypted_access_token  TEXT NOT NULL,   -- AES-256 ciphertext
    encryption_iv           TEXT NOT NULL,   -- initialization vector for decryption
    token_expires_at        TIMESTAMPTZ NOT NULL,
    last_refreshed_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Supports the 24h refresh scheduler's "which tokens need refreshing soon" query.
CREATE INDEX idx_instagram_tokens_expires_at ON instagram_tokens (token_expires_at);

-- ============================================================================
-- 3. BRAND PIPELINE
-- ============================================================================

-- The fixed taxonomy (15 content categories, 10 aesthetic styles, plus
-- audience type / tone / production quality) stored as data rather than
-- hardcoded strings scattered across brandAnalyzer.ts and every table that
-- references a classification. Swap or extend the taxonomy by editing rows
-- here, not by migrating every table that references it.
CREATE TABLE taxonomy_values (
    id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    dimension TEXT NOT NULL CHECK (dimension IN (
        'content_category', 'aesthetic_style', 'audience_type',
        'tone', 'production_quality'
    )),
    value     TEXT NOT NULL,
    UNIQUE (dimension, value)
);

-- Raw post metadata pulled from the Instagram Graph API (last 12 image posts).
CREATE TABLE posts (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    creator_id        UUID NOT NULL REFERENCES creator_profiles(user_id) ON DELETE CASCADE,
    instagram_post_id TEXT NOT NULL UNIQUE,
    media_url         TEXT,
    caption           TEXT,
    posted_at         TIMESTAMPTZ,
    fetched_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_posts_creator_id ON posts (creator_id);

-- Per-post Claude vision classification output. One row per post, matching
-- the PostAnalysis type shared across services.
CREATE TABLE post_analyses (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    post_id                  UUID NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    content_category_id      UUID REFERENCES taxonomy_values(id),
    aesthetic_style_id       UUID REFERENCES taxonomy_values(id),
    audience_type_id         UUID REFERENCES taxonomy_values(id),
    tone_id                  UUID REFERENCES taxonomy_values(id),
    production_quality_id    UUID REFERENCES taxonomy_values(id),
    confidence                NUMERIC(4,3) NOT NULL,  -- per-image confidence; used as the
                                                        -- weighting factor in the brand-profile
                                                        -- aggregation (weighted frequency counting)
    model_version              TEXT,                   -- which Claude model/prompt version ran this,
                                                        -- for reproducibility if the taxonomy or
                                                        -- prompt changes later
    analyzed_at               TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_post_analyses_post_id ON post_analyses (post_id);

-- The aggregated brand profile per creator — the weighted-frequency rollup
-- across their last analyzed posts. Stored (not recomputed on every browse)
-- since fit scoring reads this on every investor search.
CREATE TABLE brand_profiles (
    creator_id                        UUID PRIMARY KEY REFERENCES creator_profiles(user_id) ON DELETE CASCADE,
    dominant_content_category_id      UUID REFERENCES taxonomy_values(id),
    dominant_aesthetic_style_id       UUID REFERENCES taxonomy_values(id),
    dominant_audience_type_id         UUID REFERENCES taxonomy_values(id),
    dominant_tone_id                  UUID REFERENCES taxonomy_values(id),
    dominant_production_quality_id    UUID REFERENCES taxonomy_values(id),
    -- Full weighted-frequency distribution (not just the dominant/mode value),
    -- so fit scoring can weigh a creator's secondary categories too, not just
    -- their single top classification.
    category_distribution             JSONB NOT NULL DEFAULT '{}'::jsonb,
    computed_from_post_count          INTEGER NOT NULL DEFAULT 0,
    computed_at                       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Cached investor-creator 0-100 fit scores, so the browse/search experience
-- doesn't recompute the match on every page view.
CREATE TABLE fit_scores (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    investor_id   UUID NOT NULL REFERENCES investor_profiles(user_id) ON DELETE CASCADE,
    creator_id    UUID NOT NULL REFERENCES creator_profiles(user_id) ON DELETE CASCADE,
    score         NUMERIC(5,2) NOT NULL CHECK (score >= 0 AND score <= 100),
    computed_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (investor_id, creator_id)
);

CREATE INDEX idx_fit_scores_investor_id ON fit_scores (investor_id);
CREATE INDEX idx_fit_scores_creator_id ON fit_scores (creator_id);

-- ============================================================================
-- 4. CONTRACT FACILITATOR  (replaces facilitator.ts's in-memory deal Map)
-- ============================================================================

CREATE TYPE deal_status AS ENUM (
    'draft', 'funded', 'active', 'complete', 'refunded'
);

CREATE TABLE deals (
    -- Kept as the same external dealId string already used in the API
    -- (e.g. "deal_001" in the README's curl example) rather than introducing
    -- a second internal UUID that every caller would need to track alongside it.
    id                    TEXT PRIMARY KEY,
    investor_id           UUID REFERENCES investor_profiles(user_id),
    creator_id            UUID REFERENCES creator_profiles(user_id),
    investor_address      TEXT NOT NULL,
    investee_address      TEXT NOT NULL,
    contract_address      TEXT,                 -- null until deployed
    principal_usdc        NUMERIC(18,6) NOT NULL,
    return_amount_usdc    NUMERIC(18,6) NOT NULL,
    lock_days             INTEGER NOT NULL,
    acceptance_days       INTEGER NOT NULL,
    status                deal_status NOT NULL DEFAULT 'draft',

    investor_email        TEXT NOT NULL,
    influencer_email      TEXT NOT NULL,
    influencer_username   TEXT NOT NULL,
    investor_name         TEXT,

    -- Lifecycle timestamps, one per contract_status_flow transition
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    funded_at             TIMESTAMPTZ,
    accepted_at            TIMESTAMPTZ,
    completed_at           TIMESTAMPTZ,
    refunded_at             TIMESTAMPTZ,

    -- Computed deadlines, used by the contract's reclaim()/isOverdue() logic
    -- and mirrored here so the facilitator can query without hitting the chain
    acceptance_deadline    TIMESTAMPTZ,
    lock_deadline          TIMESTAMPTZ,

    -- Tracks what the 2-minute poller last observed, so it can detect
    -- transitions rather than re-processing an unchanged deal every cycle
    last_polled_status     deal_status,
    last_polled_at         TIMESTAMPTZ
);

-- Backs the poller's core query: "give me every deal that's still active
-- and might have changed state on-chain since I last checked."
CREATE INDEX idx_deals_status ON deals (status) WHERE status IN ('funded', 'active');
CREATE INDEX idx_deals_investor_id ON deals (investor_id);
CREATE INDEX idx_deals_creator_id ON deals (creator_id);

-- repay() supports installments, so a single "amount repaid" column on
-- deals can't capture the full picture — this is an append-only ledger.
CREATE TABLE repayments (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    deal_id     TEXT NOT NULL REFERENCES deals(id) ON DELETE CASCADE,
    amount_usdc NUMERIC(18,6) NOT NULL,
    tx_hash     TEXT NOT NULL,
    paid_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_repayments_deal_id ON repayments (deal_id);

-- Durable log of every typed email notification fired on a deal transition.
-- The in-memory version has no audit trail if an email silently fails to
-- send; this does.
CREATE TABLE notifications (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    deal_id            TEXT NOT NULL REFERENCES deals(id) ON DELETE CASCADE,
    notification_type  TEXT NOT NULL,   -- e.g. 'deal_funded', 'deal_accepted',
                                         -- 'deal_overdue', 'deal_completed', 'deal_refunded'
    recipient_email    TEXT NOT NULL,
    delivery_status    TEXT NOT NULL DEFAULT 'sent',
    sent_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_notifications_deal_id ON notifications (deal_id);

-- ============================================================================
-- Trigger: keep updated_at current on the tables that have it
-- ============================================================================

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_investor_profiles_updated_at
    BEFORE UPDATE ON investor_profiles
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_creator_profiles_updated_at
    BEFORE UPDATE ON creator_profiles
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================================
-- Seed data: starter taxonomy values
-- ============================================================================
-- These are PLACEHOLDER values. Replace with the actual 15 content
-- categories and 10 aesthetic styles defined in brand-pipeline/src/brandAnalyzer.ts
-- so the database matches exactly what the classification prompt uses.

INSERT INTO taxonomy_values (dimension, value) VALUES
    ('content_category', 'fitness'),
    ('content_category', 'beauty'),
    ('content_category', 'fashion'),
    ('content_category', 'food'),
    ('content_category', 'travel'),
    ('content_category', 'lifestyle'),
    ('content_category', 'tech'),
    ('content_category', 'gaming'),
    ('content_category', 'finance'),
    ('content_category', 'parenting'),
    ('content_category', 'home_design'),
    ('content_category', 'comedy'),
    ('content_category', 'education'),
    ('content_category', 'music'),
    ('content_category', 'art'),

    ('aesthetic_style', 'minimalist'),
    ('aesthetic_style', 'bold_colorful'),
    ('aesthetic_style', 'moody_dark'),
    ('aesthetic_style', 'bright_airy'),
    ('aesthetic_style', 'vintage_retro'),
    ('aesthetic_style', 'luxury_polished'),
    ('aesthetic_style', 'raw_candid'),
    ('aesthetic_style', 'editorial'),
    ('aesthetic_style', 'playful_quirky'),
    ('aesthetic_style', 'natural_organic')
ON CONFLICT (dimension, value) DO NOTHING;

-- audience_type, tone, and production_quality value sets intentionally left
-- for the project owner to populate from brandAnalyzer.ts's actual prompt
-- definition, rather than guessed here.
