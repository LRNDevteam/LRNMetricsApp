/* =====================================================================
   Payer Matching Engine - Supporting Reference Tables
   Companion DDL + seed data for docs/payer-master/Payer_Master_Reference_Tables_v1.1.md
   Target: SQL Server (T-SQL)
   Generated: 2026-07-10

   Tables created (in dependency order):
     1. USStateCode          - state/territory lookup (FK target)
     2. PayerFamilyRule      - brand-family blocking rules
     3. StateBrandMapping    - brand -> home-state resolution
     4. ProgramTypeRule      - coverage / product-line detection
     5. PlanNetworkTypeCode  - network/plan-type codes stripped in Step 1B
     6. PayerAlias           - self-learning (raw name, state) -> GlobalPayerId
                               cache, seeded from Lab Insurance Master v1.8.4

   NOTE: PayerAlias.GlobalPayerId is declared with an FK to
   PayerPolicyInsuranceMaster(GlobalPayerId). If that table name differs
   in your environment, adjust or comment out the constraint below.
   ===================================================================== */

SET NOCOUNT ON;
GO

/* =====================================================================
   1. USStateCode - US state & territory lookup
   ===================================================================== */
IF OBJECT_ID(N'dbo.USStateCode', N'U') IS NOT NULL DROP TABLE dbo.USStateCode;
GO
CREATE TABLE dbo.USStateCode (
    StateCode   CHAR(2)        NOT NULL CONSTRAINT PK_USStateCode PRIMARY KEY,
    StateName   NVARCHAR(100)  NOT NULL,
    IsActive    BIT            NOT NULL CONSTRAINT DF_USStateCode_IsActive DEFAULT (1)
);
GO

INSERT INTO dbo.USStateCode (StateCode, StateName) VALUES
    ('AL', N'Alabama'),
    ('AK', N'Alaska'),
    ('AZ', N'Arizona'),
    ('AR', N'Arkansas'),
    ('CA', N'California'),
    ('CO', N'Colorado'),
    ('CT', N'Connecticut'),
    ('DE', N'Delaware'),
    ('FL', N'Florida'),
    ('GA', N'Georgia'),
    ('HI', N'Hawaii'),
    ('ID', N'Idaho'),
    ('IL', N'Illinois'),
    ('IN', N'Indiana'),
    ('IA', N'Iowa'),
    ('KS', N'Kansas'),
    ('KY', N'Kentucky'),
    ('LA', N'Louisiana'),
    ('ME', N'Maine'),
    ('MD', N'Maryland'),
    ('MA', N'Massachusetts'),
    ('MI', N'Michigan'),
    ('MN', N'Minnesota'),
    ('MS', N'Mississippi'),
    ('MO', N'Missouri'),
    ('MT', N'Montana'),
    ('NE', N'Nebraska'),
    ('NV', N'Nevada'),
    ('NH', N'New Hampshire'),
    ('NJ', N'New Jersey'),
    ('NM', N'New Mexico'),
    ('NY', N'New York'),
    ('NC', N'North Carolina'),
    ('ND', N'North Dakota'),
    ('OH', N'Ohio'),
    ('OK', N'Oklahoma'),
    ('OR', N'Oregon'),
    ('PA', N'Pennsylvania'),
    ('RI', N'Rhode Island'),
    ('SC', N'South Carolina'),
    ('SD', N'South Dakota'),
    ('TN', N'Tennessee'),
    ('TX', N'Texas'),
    ('UT', N'Utah'),
    ('VT', N'Vermont'),
    ('VA', N'Virginia'),
    ('WA', N'Washington'),
    ('WV', N'West Virginia'),
    ('WI', N'Wisconsin'),
    ('WY', N'Wyoming'),
    ('DC', N'District of Columbia'),
    ('PR', N'Puerto Rico'),
    ('GU', N'Guam'),
    ('VI', N'U.S. Virgin Islands'),
    ('AS', N'American Samoa'),
    ('MP', N'Northern Mariana Islands');
GO

/* =====================================================================
   2. PayerFamilyRule - groups payer name variants under a parent family
   Source: payer_family_rules_v2_0.xlsx
   Priority scheme (lower = evaluated first):
      10  - specific sub-brand rules that MUST beat their parent brand
            (e.g. AETNA BETTER HEALTH before AETNA, HEALTHSPRING before
            CIGNA, AMERIHEALTH CARITAS before AMERIHEALTH, every named
            Blue brand before the generic BCBS catch-all)
      50  - standard brand rules (source priority = High)
     900  - generic catch-alls (source priority = Medium), e.g. BCBS_GENERIC
   ===================================================================== */
IF OBJECT_ID(N'dbo.PayerFamilyRule', N'U') IS NOT NULL DROP TABLE dbo.PayerFamilyRule;
GO
CREATE TABLE dbo.PayerFamilyRule (
    RuleId            INT            NOT NULL IDENTITY(1,1) CONSTRAINT PK_PayerFamilyRule PRIMARY KEY,
    Family            NVARCHAR(100)  NOT NULL,
    Pattern           NVARCHAR(400)  NOT NULL,
    DefaultEntityType NVARCHAR(50)   NULL,
    Priority          INT            NOT NULL,
    IsActive          BIT            NOT NULL CONSTRAINT DF_PayerFamilyRule_IsActive DEFAULT (1),
    CreatedBy         NVARCHAR(100)  NOT NULL,
    CreatedDate       DATETIME       NOT NULL CONSTRAINT DF_PayerFamilyRule_CreatedDate DEFAULT (GETDATE()),
    Notes             NVARCHAR(500)  NULL
);
GO
CREATE INDEX IX_PayerFamilyRule_Priority ON dbo.PayerFamilyRule (IsActive, Priority);
GO

INSERT INTO dbo.PayerFamilyRule (Family, Pattern, DefaultEntityType, Priority, IsActive, CreatedBy, CreatedDate, Notes) VALUES
    (N'UHC', N'UNITED HEALTH CARE|UNITEDHEALTHCARE|UHC|AARP|UNITED HEALTH CARE', N'Carrier', 50, 1, N'System Seed', '2026-07-10', N'National UHC family; AARP-branded Medicare Supplement/Advantage plans are UHC-underwritten'),
    (N'AETNA', N'AETNA', N'Carrier', 50, 1, N'System Seed', '2026-07-10', N'Base Aetna family'),
    (N'AETNA_BETTER_HEALTH', N'AETNA BETTER HEALTH|AETNA BETTER HEATH|BETTER HEALTH', N'Medicaid MCO', 10, 1, N'System Seed', '2026-07-10', N'Keep separate from commercial Aetna'),
    (N'CIGNA', N'CIGNA', N'Carrier', 50, 1, N'System Seed', '2026-07-10', N'Base Cigna family'),
    (N'CIGNA_HEALTHSPRING', N'HEALTHSPRING|CIGNA HEALTHSPRING', N'Medicare MCO', 10, 1, N'System Seed', '2026-07-10', N'Medicare-specific Cigna line'),
    (N'HUMANA', N'HUMANA', N'Carrier', 50, 1, N'System Seed', '2026-07-10', NULL),
    (N'MOLINA', N'MOLINA', N'Medicaid MCO', 50, 1, N'System Seed', '2026-07-10', NULL),
    (N'WELLCARE', N'WELLCARE', N'Carrier', 50, 1, N'System Seed', '2026-07-10', N'Program/state still needed'),
    (N'AMBETTER', N'AMBETTER', N'Marketplace Plan', 50, 1, N'System Seed', '2026-07-10', N'Centene exchange brand'),
    (N'CARESOURCE', N'CARESOURCE', N'Medicaid MCO', 50, 1, N'System Seed', '2026-07-10', NULL),
    (N'MERIDIAN', N'MERIDIAN|MERIDAN', N'Medicaid MCO', 50, 1, N'System Seed', '2026-07-10', NULL),
    (N'HOME_STATE_HEALTH', N'HOME STATE HEALTH', N'Medicaid MCO', 50, 1, N'System Seed', '2026-07-10', N'Centene Missouri brand'),
    (N'MAGNOLIA', N'MAGNOLIA|MAGNOLIAHEALTH|MAGNOLIA HEALTH|MAGNOLIA HEALTH PLAN|MAGNOLIAHEALTHPLAN', N'Marketplace Plan', 50, 1, N'System Seed', '2026-07-10', N'Ambetter/Magnolia context'),
    (N'ABSOLUTE_TOTAL_CARE', N'ABSOLUTE TOTAL CARE', N'Medicaid MCO', 50, 1, N'System Seed', '2026-07-10', NULL),
    (N'SUPERIOR_HEALTH', N'SUPERIOR HEALTH', N'Medicaid MCO', 50, 1, N'System Seed', '2026-07-10', N'Texas Centene brand'),
    (N'SUNSHINE_HEALTH', N'SUNSHINE HEALTH', N'Medicaid MCO', 50, 1, N'System Seed', '2026-07-10', N'Florida Centene brand'),
    (N'ARKANSAS_TOTAL_CARE', N'ARKANSAS TOTAL CARE', N'Medicaid MCO', 50, 1, N'System Seed', '2026-07-10', NULL),
    (N'PEACH_STATE', N'PEACH STATE', N'Medicaid MCO', 50, 1, N'System Seed', '2026-07-10', N'Georgia Centene brand'),
    (N'SILVER_SUMMIT', N'SILVER SUMMIT', N'Medicaid MCO', 50, 1, N'System Seed', '2026-07-10', N'Nevada Centene brand'),
    (N'SUNFLOWER_HEALTH', N'SUNFLOWER HEALTH|SUNFLOWER', N'Medicaid MCO', 50, 1, N'System Seed', '2026-07-10', N'Kansas Centene brand'),
    (N'WESTERN_SKY', N'WESTERN SKY', N'Medicaid MCO', 50, 1, N'System Seed', '2026-07-10', N'New Mexico Centene brand'),
    (N'LOUISIANA_HEALTHCARE_CONNECTIONS', N'LOUISIANA HEALTHCARE CONNECTIONS', N'Medicaid MCO', 50, 1, N'System Seed', '2026-07-10', N'Louisiana Centene brand'),
    (N'COORDINATED_CARE', N'COORDINATED CARE', N'Medicaid MCO', 50, 1, N'System Seed', '2026-07-10', N'Washington Centene brand; ''Coordinated Care'' is also a generic industry term, verify false positives'),
    (N'MHS_INDIANA', N'MANAGED HEALTH SERVICES|MHS', N'Medicaid MCO', 50, 1, N'System Seed', '2026-07-10', N'Indiana Centene brand; bare ''MHS'' is ambiguous, prefer full name where possible'),
    (N'NE_TOTAL_CARE', N'NE TOTAL CARE|NEBRASKA TOTAL CARE', N'Medicaid MCO', 50, 1, N'System Seed', '2026-07-10', N'Nebraska Centene brand'),
    (N'NH_HEALTHY_FAMILIES', N'NH HEALTHY FAMILIES', N'Medicaid MCO', 50, 1, N'System Seed', '2026-07-10', N'New Hampshire Centene brand'),
    (N'PA_HEALTH_WELLNESS', N'PA HEALTH & WELLNESS|PA HEALTH AND WELLNESS|PENNSYLVANIA HEALTH & WELLNESS', N'Medicaid MCO', 50, 1, N'System Seed', '2026-07-10', N'Pennsylvania Centene brand'),
    (N'AZ_COMPLETE_HEALTH', N'AZ COMPLETE HEALTH|ARIZONA COMPLETE HEALTH|ARIZONA COMPLETE CARE', N'Medicaid MCO', 50, 1, N'System Seed', '2026-07-10', N'Arizona Centene brand'),
    (N'AR_HEALTH_WELLNESS', N'AR HEALTH & WELLNESS|AR HEALTH AND WELLNESS|ARKANSAS HEALTH & WELLNESS', N'Medicaid MCO', 50, 1, N'System Seed', '2026-07-10', N'Arkansas Centene brand'),
    (N'BUCKEYE_HEALTH', N'BUCKEYE HEALTH|BUCKEYE', N'Medicaid MCO', 50, 1, N'System Seed', '2026-07-10', N'Ohio Centene brand; bare ''Buckeye'' is a common OH state nickname, prefer ''BUCKEYE HEALTH'' adjacency'),
    (N'AMERIGROUP', N'AMERIGROUP', N'Medicaid MCO', 50, 1, N'System Seed', '2026-07-10', N'Anthem-owned national Medicaid brand'),
    (N'WELLPOINT', N'WELLPOINT', N'Medicaid MCO', 50, 1, N'System Seed', '2026-07-10', N'Anthem''s current Medicaid-line brand name in several states (IA, IN, KY, NE, NV, VA, WI) - resurrected corporate name, not the same as generic BCBS'),
    (N'HEALTHY_BLUE', N'HEALTHY BLUE', N'Medicaid MCO', 50, 1, N'System Seed', '2026-07-10', N'Anthem''s Medicaid MCO brand across several states'),
    (N'SIMPLY_HEALTHCARE', N'SIMPLY HEALTHCARE', N'Medicaid MCO', 50, 1, N'System Seed', '2026-07-10', N'Florida - Anthem-owned Medicaid plan'),
    (N'CLEAR_HEALTH_ALLIANCE', N'CLEAR HEALTH ALLIANCE', N'Medicaid MCO', 50, 1, N'System Seed', '2026-07-10', N'Florida - Anthem-owned specialty (HIV/AIDS) Medicaid plan'),
    (N'ANTHEM_BCBS', N'ANTHEM|EMPIRE BLUECROSS|EMPIRE BCBS|EMPIRE BLUE CROSS', N'Carrier', 10, 1, N'System Seed', '2026-07-10', N'Anthem-branded BCBS licensee (CA, CO, CT, GA, IN, KY, ME, MO, NH, NV, NY-as Empire, OH, VA, WI). CAUTION: do not extend pattern to bare ''EMPIRE'' - ''The Empire Plan'' is NY State''s own employee health plan administered by UnitedHealthcare, unrelated to Anthem'),
    (N'HIGHMARK_BCBS', N'HIGHMARK|HIGHMARK BCBS', N'Carrier', 10, 1, N'System Seed', '2026-07-10', N'PA, WV, DE, western NY'),
    (N'CAREFIRST_BCBS', N'CAREFIRST|CAREFIRST BCBS|CAREFIRSTBCBS', N'Carrier', 10, 1, N'System Seed', '2026-07-10', N'MD, DC, Northern VA - multi-jurisdiction, no single home state'),
    (N'REGENCE_BCBS', N'REGENCE|REGENCE BCBS|REGENCBCBS', N'Carrier', 10, 1, N'System Seed', '2026-07-10', N'OR, WA, ID, UT - multi-state, no single home state'),
    (N'WELLMARK_BCBS', N'WELLMARK|WELLMARK BCBS|WELLMARKBCBS', N'Carrier', 10, 1, N'System Seed', '2026-07-10', N'IA, SD - two-state brand, no single home state'),
    (N'INDEPENDENCE_BCBS', N'INDEPENDENCE BLUE CROSS|INDEPENDENCE', N'Carrier', 10, 1, N'System Seed', '2026-07-10', N'Philadelphia PA region; do not confuse with unrelated ''Independent Health'' (Buffalo NY)'),
    (N'CAPITAL_BCBS', N'CAPITAL BLUE CROSS', N'Carrier', 10, 1, N'System Seed', '2026-07-10', N'Central PA region'),
    (N'HMSA', N'HMSA|HAWAII MEDICAL SERVICE', N'Carrier', 10, 1, N'System Seed', '2026-07-10', N'Hawaii'),
    (N'EXCELLUS_BCBS', N'EXCELLUS|EXCELLUS BCBS|EXCELLUS BSBS', N'Carrier', 10, 1, N'System Seed', '2026-07-10', N'Upstate/Central NY'),
    (N'HORIZON_BCBS', N'HORIZON|HORIZON BCBS|HORIZONBCBS', N'Carrier', 10, 1, N'System Seed', '2026-07-10', N'NJ - ''Horizon'' is a common word, tighten pattern (e.g. require BLUE adjacency) if false positives appear'),
    (N'BLUE_SHIELD_CA', N'BLUE SHIELD OF CALIFORNIA|BLUE SHIELD CA', N'Carrier', 10, 1, N'System Seed', '2026-07-10', N'Distinct legal entity from Anthem Blue Cross of California - same state, different company, do not merge'),
    (N'FLORIDA_BLUE', N'FLORIDA BLUE|FL BLUE', N'Carrier', 10, 1, N'System Seed', '2026-07-10', N'FL - GuideWell/BCBS FL brand name'),
    (N'PREMERA_BCBS', N'PREMERA', N'Carrier', 10, 1, N'System Seed', '2026-07-10', N'WA, AK'),
    (N'BLUE_CARE_NETWORK', N'BLUE CARE NETWORK|BCN', N'HMO', 10, 1, N'System Seed', '2026-07-10', N'Michigan HMO arm of BCBS Michigan; flag separately since ''BCN'' won''t contain Blue Cross wording'),
    (N'BCBS_GENERIC', N'BLUE CROSS|BLUE SHIELD|BCBS', N'Carrier', 900, 1, N'System Seed', '2026-07-10', N'Catch-all for state BCBS licensees without a distinct non-''Blue'' brand name (e.g. BCBS of Texas, BCBS of Michigan, BCBS of North Carolina, BCBS Massachusetts). Must be evaluated AFTER every brand-specific Blue-family rule above or those brands get miscategorized generically - this exact bug was found and fixed twice already in the Payer Policy Master v1.9 classification (Independence/Capital Blue Cross, then Anthem)'),
    (N'KAISER', N'KAISER|KAISER PERMANENTE', N'Carrier', 50, 1, N'System Seed', '2026-07-10', NULL),
    (N'AMERIHEALTH', N'AMERIHEALTH', N'Carrier', 50, 1, N'System Seed', '2026-07-10', N'PA/NJ/DE commercial plus AmeriHealth Caritas Medicaid MCO in multiple states - same brand root'),
    (N'AMERIHEALTH_CARITAS', N'AMERIHEALTH CARITAS', N'Medicaid MCO', 10, 1, N'System Seed', '2026-07-10', NULL),
    (N'HAP', N'HEALTH ALLIANCE PLAN|HAP MIDWEST|HAP', N'Carrier', 50, 1, N'System Seed', '2026-07-10', N'Michigan; bare ''HAP'' is short and ambiguous, verify false positives'),
    (N'ALLIED_BENEFIT', N'ALLIED BENEFIT', N'TPA', 50, 1, N'System Seed', '2026-07-10', NULL),
    (N'EMBLEMHEALTH', N'EMBLEMHEALTH|GHI|HIP HEALTH PLAN', N'Carrier', 50, 1, N'System Seed', '2026-07-10', N'NY - GHI and HIP are EmblemHealth''s legacy brand names; avoid bare ''HIP'' (too ambiguous), require ''HIP HEALTH PLAN'''),
    (N'HEALTH_NET', N'HEALTH NET|HEALTHNET', N'Carrier', 50, 1, N'System Seed', '2026-07-10', NULL),
    (N'OSCAR_HEALTH', N'OSCAR HEALTH', N'Marketplace Plan', 50, 1, N'System Seed', '2026-07-10', N'Prefer requiring ''HEALTH'' adjacency over bare ''OSCAR'' to avoid false positives'),
    (N'BRIGHT_HEALTH', N'BRIGHT HEALTH', N'Carrier', 50, 1, N'System Seed', '2026-07-10', N'Exited most markets 2022-23 - retained for legacy claims'),
    (N'OXFORD_HEALTH', N'OXFORD HEALTH', N'Carrier', 50, 1, N'System Seed', '2026-07-10', N'UHC subsidiary, NY/NJ/CT - kept distinct because still visible on plan cards'),
    (N'PRESBYTERIAN_HEALTH', N'PRESBYTERIAN HEALTH', N'Carrier', 50, 1, N'System Seed', '2026-07-10', N'NM - consolidate variant spellings; already flagged as a data-quality item (3 near-duplicate rows) in the client''s Payer Policy Master v1.9'),
    (N'MEDICA', N'MEDICA', N'Carrier', 50, 1, N'System Seed', '2026-07-10', N'MN - bare word, verify against false positives'),
    (N'HEALTHPARTNERS', N'HEALTHPARTNERS|HEALTH PARTNERS', N'Carrier', 50, 1, N'System Seed', '2026-07-10', N'MN'),
    (N'SCAN_HEALTH', N'SCAN HEALTH PLAN|SCAN HEALTH', N'Medicare MCO', 50, 1, N'System Seed', '2026-07-10', N'CA Medicare Advantage; prefer requiring ''HEALTH PLAN'' adjacency over bare ''SCAN'''),
    (N'DEVOTED_HEALTH', N'DEVOTED HEALTH', N'Medicare MCO', 50, 1, N'System Seed', '2026-07-10', NULL),
    (N'CLOVER_HEALTH', N'CLOVER HEALTH', N'Medicare MCO', 50, 1, N'System Seed', '2026-07-10', NULL),
    (N'ALIGNMENT_HEALTHCARE', N'ALIGNMENT HEALTHCARE', N'Medicare MCO', 50, 1, N'System Seed', '2026-07-10', NULL),
    (N'GEISINGER', N'GEISINGER', N'Carrier', 50, 1, N'System Seed', '2026-07-10', N'PA'),
    (N'UPMC_HEALTH_PLAN', N'UPMC', N'Carrier', 50, 1, N'System Seed', '2026-07-10', N'PA'),
    (N'INDEPENDENT_HEALTH', N'INDEPENDENT HEALTH', N'Carrier', 50, 1, N'System Seed', '2026-07-10', N'Buffalo NY - do not confuse with unrelated ''Independence Blue Cross'' (Philadelphia PA)'),
    (N'FIDELIS_CARE', N'FIDELIS CARE|FIDELIS', N'Medicaid MCO', 50, 1, N'System Seed', '2026-07-10', N'NY - Centene-owned'),
    (N'HEALTHFIRST', N'HEALTHFIRST', N'Carrier', 50, 1, N'System Seed', '2026-07-10', N'NYC-area'),
    (N'METROPLUS', N'METROPLUS', N'Medicaid MCO', 50, 1, N'System Seed', '2026-07-10', N'NYC public hospital system plan'),
    (N'CDPHP', N'CDPHP', N'Carrier', 50, 1, N'System Seed', '2026-07-10', N'Capital District NY (Albany area)'),
    (N'MVP_HEALTHCARE', N'MVP HEALTHCARE|MVP HEALTH CARE', N'Carrier', 50, 1, N'System Seed', '2026-07-10', N'NY/VT - bare ''MVP'' is ambiguous, prefer full brand match'),
    (N'PRIORITY_HEALTH', N'PRIORITY HEALTH', N'Carrier', 50, 1, N'System Seed', '2026-07-10', N'MI'),
    (N'TUFTS_HEALTH', N'TUFTS HEALTH|TUFTS', N'Carrier', 50, 1, N'System Seed', '2026-07-10', N'MA - now part of Point32Health along with Harvard Pilgrim'),
    (N'HARVARD_PILGRIM', N'HARVARD PILGRIM', N'Carrier', 50, 1, N'System Seed', '2026-07-10', N'MA/NH/ME - part of Point32Health'),
    (N'WELLSENSE', N'WELLSENSE', N'Medicaid MCO', 50, 1, N'System Seed', '2026-07-10', N'MA/NH - formerly BMC HealthNet Plan'),
    (N'GEHA', N'GEHA', N'Federal', 50, 1, N'System Seed', '2026-07-10', N'Federal employee plan carrier (distinct from FEP Blue)'),
    (N'ALLEGIANCE', N'ALLEGIANCE', N'TPA', 50, 1, N'System Seed', '2026-07-10', NULL),
    (N'LUCENT_HEALTH', N'LUCENT', N'TPA', 50, 1, N'System Seed', '2026-07-10', NULL),
    (N'MERITAIN', N'MERITAIN', N'TPA', 50, 1, N'System Seed', '2026-07-10', NULL),
    (N'UMR', N'\bUMR\b', N'TPA', 50, 1, N'System Seed', '2026-07-10', NULL),
    (N'SUREST', N'SUREST', N'Product Line', 50, 1, N'System Seed', '2026-07-10', N'Treat separate from base UHC'),
    (N'GOLDEN_RULE', N'GOLDEN RULE', N'Carrier', 50, 1, N'System Seed', '2026-07-10', N'Treat separate from base UHC'),
    (N'SHARED_SERVICES', N'SHARED SERVICES', N'TPA', 50, 1, N'System Seed', '2026-07-10', N'Often UHC shared services'),
    (N'TRICARE', N'TRICARE|CHAMPVA|CHAMPUS|HUMANA MILITARY', N'Federal', 50, 1, N'System Seed', '2026-07-10', N'Humana is the TRICARE East Region contractor'),
    (N'PALMETTO_GBA', N'PALMETTO GBA|RAILROAD MEDICARE|RRB', N'Federal', 50, 1, N'System Seed', '2026-07-10', N'Railroad Retirement Board Medicare Administrative Contractor - handles Medicare claims for railroad retirees nationwide'),
    (N'MEDICAID_GENERIC', N'\bMEDICAID\b', N'Medicaid Program', 900, 1, N'System Seed', '2026-07-10', N'Fallback only'),
    (N'MEDICARE_GENERIC', N'\bMEDICARE\b', N'Medicare Program', 900, 1, N'System Seed', '2026-07-10', N'Fallback only');
GO

/* =====================================================================
   3. StateBrandMapping - brand -> known home state (Step 2 resolution)
   Source: state_brand_mapping_v2_0.xlsx
   StateCode is nullable on purpose: a row may exist to carry the
   normalized brand name while flagging "state must come from raw name
   or manual review" (e.g. HEALTH FIRST HEALTH PLANS).
   ===================================================================== */
IF OBJECT_ID(N'dbo.StateBrandMapping', N'U') IS NOT NULL DROP TABLE dbo.StateBrandMapping;
GO
CREATE TABLE dbo.StateBrandMapping (
    MappingId           INT            NOT NULL IDENTITY(1,1) CONSTRAINT PK_StateBrandMapping PRIMARY KEY,
    BrandKeyword        NVARCHAR(100)  NOT NULL,
    StateCode           CHAR(2)        NULL
        CONSTRAINT FK_StateBrandMapping_State REFERENCES dbo.USStateCode (StateCode),
    NormalizedBrandName NVARCHAR(200)  NULL,
    IsActive            BIT            NOT NULL CONSTRAINT DF_StateBrandMapping_IsActive DEFAULT (1),
    CreatedBy           NVARCHAR(100)  NOT NULL,
    CreatedDate         DATETIME       NOT NULL CONSTRAINT DF_StateBrandMapping_CreatedDate DEFAULT (GETDATE()),
    Notes               NVARCHAR(500)  NULL
);
GO
CREATE UNIQUE INDEX UX_StateBrandMapping_BrandKeyword ON dbo.StateBrandMapping (BrandKeyword);
GO

INSERT INTO dbo.StateBrandMapping (BrandKeyword, StateCode, NormalizedBrandName, IsActive, CreatedBy, CreatedDate, Notes) VALUES
    (N'HOME STATE HEALTH', 'MO', N'Home State Health MO Medicaid', 1, N'System Seed', '2026-07-10', N'Missouri Centene Medicaid brand'),
    (N'MAGNOLIA', 'MS', N'Magnolia MS', 1, N'System Seed', '2026-07-10', N'Mississippi brand'),
    (N'SUPERIOR HEALTH', 'TX', N'Superior Health TX', 1, N'System Seed', '2026-07-10', N'Texas brand'),
    (N'SUNSHINE HEALTH', 'FL', N'Sunshine Health FL', 1, N'System Seed', '2026-07-10', N'Florida brand'),
    (N'BUCKEYE', 'OH', N'Buckeye OH', 1, N'System Seed', '2026-07-10', N'Ohio brand'),
    (N'ARIZONA COMPLETE CARE', 'AZ', N'Arizona Complete Care AZ', 1, N'System Seed', '2026-07-10', NULL),
    (N'ARKANSAS TOTAL CARE', 'AR', N'Arkansas Total Care AR', 1, N'System Seed', '2026-07-10', NULL),
    (N'ABSOLUTE TOTAL CARE', 'SC', N'Absolute Total Care SC', 1, N'System Seed', '2026-07-10', NULL),
    (N'AMBETTER FROM MAGNOLIA', 'MS', N'Ambetter Magnolia MS', 1, N'System Seed', '2026-07-10', NULL),
    (N'AMBETTER FROM LOUISIANA HEALTHCARE', 'LA', N'Ambetter Louisiana LA', 1, N'System Seed', '2026-07-10', NULL),
    (N'AMBETTER FROM NEW HAMPSHIRE', 'NH', N'Ambetter New Hampshire NH', 1, N'System Seed', '2026-07-10', NULL),
    (N'AMBETTER FROM MERIDIAN', 'MI', N'Ambetter Meridian MI', 1, N'System Seed', '2026-07-10', NULL),
    (N'WELLCARE BY HEALTH NET', 'CA', N'WellCare Health Net CA', 1, N'System Seed', '2026-07-10', NULL),
    (N'HEALTH FIRST COLORADO', 'CO', N'Medicaid CO', 1, N'System Seed', '2026-07-10', N'Program-level Colorado Medicaid naming'),
    (N'HEALTH FIRST HEALTH PLANS', NULL, N'Health First Health Plans', 1, N'System Seed', '2026-07-10', N'State must come from raw or manual review'),
    (N'BANNER', 'AZ', N'Banner AZ', 1, N'System Seed', '2026-07-10', N'Default Banner geography'),
    (N'MERIDIAN HEALTH PLAN MICH', 'MI', N'Meridian MI Medicaid', 1, N'System Seed', '2026-07-10', NULL),
    (N'HMSA', 'HI', N'Hawaii Medical Service Association HI', 1, N'System Seed', '2026-07-10', NULL),
    (N'INDEPENDENCE BLUE CROSS', 'PA', N'Independence Blue Cross PA (Philadelphia region)', 1, N'System Seed', '2026-07-10', N'Do not confuse with unrelated Independent Health (Buffalo NY)'),
    (N'CAPITAL BLUE CROSS', 'PA', N'Capital Blue Cross PA (Central PA region)', 1, N'System Seed', '2026-07-10', N'PA has multiple regional Blues (Independence-Philadelphia, Capital-Central PA, Highmark-Western PA) - state alone won''t disambiguate among them, rely on brand-name match first'),
    (N'FLORIDA BLUE', 'FL', N'Florida Blue FL', 1, N'System Seed', '2026-07-10', N'GuideWell/BCBS FL brand name'),
    (N'BLUE SHIELD OF CALIFORNIA', 'CA', N'Blue Shield of California CA', 1, N'System Seed', '2026-07-10', N'Distinct from Anthem Blue Cross of California - same state, different legal entity, do not merge'),
    (N'EXCELLUS', 'NY', N'Excellus BCBS NY (Upstate/Central NY)', 1, N'System Seed', '2026-07-10', NULL),
    (N'HORIZON', 'NJ', N'Horizon BCBS NJ', 1, N'System Seed', '2026-07-10', N'''Horizon'' is a common word - verify context (e.g. require BLUE adjacency) before relying on this default'),
    (N'EMPIRE BLUECROSS', 'NY', N'Empire BlueCross BlueShield NY', 1, N'System Seed', '2026-07-10', N'CAUTION: do NOT use bare ''EMPIRE'' - ''The Empire Plan'' is NY State''s own employee health plan administered by UnitedHealthcare, unrelated to Anthem/Empire BlueCross. Pattern requires ''BLUECROSS''/''BCBS'' adjacency to avoid this collision, keep it that way'),
    (N'EMBLEMHEALTH', 'NY', N'EmblemHealth NY', 1, N'System Seed', '2026-07-10', NULL),
    (N'FIDELIS CARE', 'NY', N'Fidelis Care NY', 1, N'System Seed', '2026-07-10', NULL),
    (N'HEALTHFIRST', 'NY', N'Healthfirst NY', 1, N'System Seed', '2026-07-10', NULL),
    (N'METROPLUS', 'NY', N'MetroPlus Health NY', 1, N'System Seed', '2026-07-10', NULL),
    (N'CDPHP', 'NY', N'CDPHP NY (Capital District/Albany)', 1, N'System Seed', '2026-07-10', NULL),
    (N'INDEPENDENT HEALTH', 'NY', N'Independent Health NY (Buffalo)', 1, N'System Seed', '2026-07-10', N'Do not confuse with Independence Blue Cross (PA) - different, unrelated company'),
    (N'GEISINGER', 'PA', N'Geisinger Health Plan PA', 1, N'System Seed', '2026-07-10', NULL),
    (N'UPMC', 'PA', N'UPMC Health Plan PA', 1, N'System Seed', '2026-07-10', NULL),
    (N'BLUE CARE NETWORK', 'MI', N'Blue Care Network MI', 1, N'System Seed', '2026-07-10', NULL),
    (N'HEALTH ALLIANCE PLAN', 'MI', N'Health Alliance Plan (HAP) MI', 1, N'System Seed', '2026-07-10', NULL),
    (N'PRIORITY HEALTH', 'MI', N'Priority Health MI', 1, N'System Seed', '2026-07-10', NULL),
    (N'TUFTS HEALTH PLAN', 'MA', N'Tufts Health Plan MA', 1, N'System Seed', '2026-07-10', NULL),
    (N'HARVARD PILGRIM', 'MA', N'Harvard Pilgrim MA (also NH/ME - dominant MA)', 1, N'System Seed', '2026-07-10', N'Multi-state (MA/NH/ME); treat as weak default only, verify against lab state in New England'),
    (N'WELLSENSE', 'MA', N'WellSense Health Plan MA (also NH - dominant MA)', 1, N'System Seed', '2026-07-10', N'Multi-state (MA/NH); verify'),
    (N'MEDICA', 'MN', N'Medica MN', 1, N'System Seed', '2026-07-10', NULL),
    (N'HEALTHPARTNERS', 'MN', N'HealthPartners MN', 1, N'System Seed', '2026-07-10', NULL),
    (N'SCAN HEALTH PLAN', 'CA', N'SCAN Health Plan CA', 1, N'System Seed', '2026-07-10', NULL),
    (N'PRESBYTERIAN HEALTH', 'NM', N'Presbyterian Health Plan NM', 1, N'System Seed', '2026-07-10', N'Also see data-quality note on 3 near-duplicate Presbyterian rows in Payer Policy Master v1.9'),
    (N'PEACH STATE', 'GA', N'Peach State Health Plan GA', 1, N'System Seed', '2026-07-10', NULL),
    (N'SILVER SUMMIT', 'NV', N'Silver Summit Health Plan NV', 1, N'System Seed', '2026-07-10', NULL),
    (N'SUNFLOWER HEALTH', 'KS', N'Sunflower Health Plan KS', 1, N'System Seed', '2026-07-10', NULL),
    (N'WESTERN SKY', 'NM', N'Western Sky Community Care NM', 1, N'System Seed', '2026-07-10', NULL),
    (N'LOUISIANA HEALTHCARE CONNECTIONS', 'LA', N'Louisiana Healthcare Connections LA', 1, N'System Seed', '2026-07-10', NULL),
    (N'COORDINATED CARE', 'WA', N'Coordinated Care WA', 1, N'System Seed', '2026-07-10', NULL),
    (N'MANAGED HEALTH SERVICES', 'IN', N'Managed Health Services (MHS) IN', 1, N'System Seed', '2026-07-10', NULL),
    (N'NE TOTAL CARE', 'NE', N'NE Total Care NE', 1, N'System Seed', '2026-07-10', NULL),
    (N'NH HEALTHY FAMILIES', 'NH', N'NH Healthy Families NH', 1, N'System Seed', '2026-07-10', NULL),
    (N'PA HEALTH & WELLNESS', 'PA', N'PA Health & Wellness PA', 1, N'System Seed', '2026-07-10', NULL),
    (N'AR HEALTH & WELLNESS', 'AR', N'AR Health & Wellness AR', 1, N'System Seed', '2026-07-10', NULL),
    (N'CAREFIRST', 'MD', N'CareFirst BCBS MD (also DC/Northern VA - dominant MD)', 1, N'System Seed', '2026-07-10', N'Multi-jurisdiction (MD/DC/No. VA); treat as weak default only, verify against lab state near DC metro'),
    (N'REGENCE', 'OR', N'Regence BCBS OR (also WA/ID/UT - dominant OR)', 1, N'System Seed', '2026-07-10', N'Multi-state (OR/WA/ID/UT); treat as weak default only, verify against lab state in Pacific Northwest/Mountain West'),
    (N'PREMERA', 'WA', N'Premera BCBS WA (also AK - dominant WA)', 1, N'System Seed', '2026-07-10', N'Multi-state (WA/AK); verify against lab state for AK claims');
GO

/* =====================================================================
   4. ProgramTypeRule - Medicare/Medicaid/Commercial/Exchange/Federal/Dual
   Source: ProgramTypeRule_v1_0.xlsx
   Pattern is nullable: the Commercial fallback row (Priority 999)
   intentionally has no pattern - it applies when nothing above matched.
   ===================================================================== */
IF OBJECT_ID(N'dbo.ProgramTypeRule', N'U') IS NOT NULL DROP TABLE dbo.ProgramTypeRule;
GO
CREATE TABLE dbo.ProgramTypeRule (
    RuleId      INT            NOT NULL CONSTRAINT PK_ProgramTypeRule PRIMARY KEY,
    ProgramType NVARCHAR(50)   NOT NULL,
    Pattern     NVARCHAR(400)  NULL,
    Priority    INT            NOT NULL,
    IsActive    BIT            NOT NULL CONSTRAINT DF_ProgramTypeRule_IsActive DEFAULT (1),
    CreatedBy   NVARCHAR(100)  NOT NULL,
    CreatedDate DATETIME       NOT NULL CONSTRAINT DF_ProgramTypeRule_CreatedDate DEFAULT (GETDATE()),
    Notes       NVARCHAR(500)  NULL
);
GO
CREATE INDEX IX_ProgramTypeRule_Priority ON dbo.ProgramTypeRule (IsActive, Priority);
GO

INSERT INTO dbo.ProgramTypeRule (RuleId, ProgramType, Pattern, Priority, IsActive, CreatedBy, CreatedDate, Notes) VALUES
    (1, N'Dual', N'\bDUAL\b|\bDUAL COMPLETE\b|\bDUAL ELIGIBLE\b|\bMMAI\b|\bMMP\b|\bD-SNP\b|\bDSNP\b', 5, 1, N'System Seed', '2026-07-10', N'Most specific - must be evaluated before plain Medicare/Medicaid rows below, or dual-eligible plans get miscategorized as just one or the other'),
    (2, N'Medicare', N'\bRAILROAD MEDICARE\b|\bRRB\b|\bPALMETTO GBA\b', 8, 1, N'System Seed', '2026-07-10', N'Railroad Retirement Board Medicare, administered by Palmetto GBA - more specific than generic Medicare, evaluate first'),
    (3, N'Medicaid', N'\bMEDICAID\b|\bIDPA\b|\bBETTER HEALTH\b|\bMANAGED MEDICAID\b|\bCHIP\b', 10, 1, N'System Seed', '2026-07-10', N'IDPA = Illinois Department of Public Aid, legacy term still seen on some Illinois Medicaid claims/cards. CHIP bundled here pending business confirmation on separate handling'),
    (4, N'Medicare', N'\bMEDICARE\b|\bMEDICARE ADVANTAGE\b|\bHEALTHSPRING\b|\bAARP\b|\bALLWELL\b|\bSNP\b|\bPFFS\b|\bMEDIGAP\b|\bMEDICARE SUPPLEMENT\b|\bPART D\b|\bPDP\b', 10, 1, N'System Seed', '2026-07-10', N'AARP-branded plans are UHC-underwritten Medicare Supplement/Advantage, not a separate carrier'),
    (5, N'Exchange', N'\bMARKETPLACE\b|\bEXCHANGE\b|\bQHP\b|\bON EXCHANGE\b|\bOFF EXCHANGE\b|\bAMBETTER\b', 20, 1, N'System Seed', '2026-07-10', N'Ambetter is Centene''s ACA marketplace brand'),
    (6, N'Federal', N'\bFEP\b|\bFEPBLUE\b|\bFEDERAL EMPLOYEE\b|\bFEHB\b|\bTRICARE\b|\bCHAMPVA\b|\bCHAMPUS\b|\bHUMANA MILITARY\b|\bGEHA\b', 20, 1, N'System Seed', '2026-07-10', N'Covers both civilian federal employee coverage (FEP/FEHB/GEHA) and military/veteran coverage (TRICARE/CHAMPVA) under one ProgramType - split into two rows if the business wants to distinguish them downstream'),
    (7, N'Commercial', NULL, 999, 1, N'System Seed', '2026-07-10', N'Default fallback - applied when no rule above matches. Must be evaluated last; empty Pattern is intentional, not a data error');
GO

/* =====================================================================
   4b. ProductLineRule - product-line keyword rules with program/entity
       overrides and plan-type-only markers
   Source: product_line_rules_v2_0.xlsx
   This is the richer, row-per-keyword companion to ProgramTypeRule:
   ProgramTypeRule answers "what ProgramType is this" for Step 3/7
   scoring; ProductLineRule additionally carries the entity override
   and flags plan-type-only tokens (HMO/PPO/...) which have no
   program/entity override and are handled by Step 1B stripping.
   ===================================================================== */
IF OBJECT_ID(N'dbo.ProductLineRule', N'U') IS NOT NULL DROP TABLE dbo.ProductLineRule;
GO
CREATE TABLE dbo.ProductLineRule (
    RuleId          INT            NOT NULL IDENTITY(1,1) CONSTRAINT PK_ProductLineRule PRIMARY KEY,
    ProductCode     NVARCHAR(50)   NOT NULL,
    Pattern         NVARCHAR(400)  NOT NULL,
    ProgramOverride NVARCHAR(50)   NULL,
    EntityOverride  NVARCHAR(50)   NULL,
    IsActive        BIT            NOT NULL CONSTRAINT DF_ProductLineRule_IsActive DEFAULT (1),
    CreatedBy       NVARCHAR(100)  NOT NULL,
    CreatedDate     DATETIME       NOT NULL CONSTRAINT DF_ProductLineRule_CreatedDate DEFAULT (GETDATE()),
    Notes           NVARCHAR(500)  NULL
);
GO
CREATE UNIQUE INDEX UX_ProductLineRule_ProductCode ON dbo.ProductLineRule (ProductCode);
GO

INSERT INTO dbo.ProductLineRule (ProductCode, Pattern, ProgramOverride, EntityOverride, IsActive, CreatedBy, CreatedDate, Notes) VALUES
    (N'COMMUNITY_PLAN', N'COMMUNITY PLAN', N'Medicaid', N'Medicaid MCO', 1, N'System Seed', '2026-07-10', N'UHC Community Plan usually Medicaid'),
    (N'BETTER_HEALTH', N'BETTER HEALTH', N'Medicaid', N'Medicaid MCO', 1, N'System Seed', '2026-07-10', NULL),
    (N'HEALTHSPRING', N'HEALTHSPRING', N'Medicare', N'Medicare MCO', 1, N'System Seed', '2026-07-10', NULL),
    (N'ADVANTAGE', N'ADVANTAGE|MEDICARE ADVANTAGE', N'Medicare', N'Medicare MCO', 1, N'System Seed', '2026-07-10', NULL),
    (N'DUAL', N'DUAL|DUAL COMPLETE|DUAL ELIGIBLE|MMAI|MMP|D-SNP|DSNP', N'Dual', N'Dual Eligible Plan', 1, N'System Seed', '2026-07-10', N'Evaluate before plain Medicare/Medicaid rows - dual plans can trigger both keywords'),
    (N'SHARED_SERVICES', N'SHARED SERVICES', N'Commercial', N'TPA', 1, N'System Seed', '2026-07-10', NULL),
    (N'SUREST', N'SUREST', N'Commercial', N'Product Line', 1, N'System Seed', '2026-07-10', NULL),
    (N'GOLDEN_RULE', N'GOLDEN RULE', N'Commercial', N'Carrier', 1, N'System Seed', '2026-07-10', NULL),
    (N'AARP', N'AARP', N'Medicare', N'Medicare MCO', 1, N'System Seed', '2026-07-10', NULL),
    (N'ALLWELL', N'ALLWELL', N'Medicare', N'Medicare MCO', 1, N'System Seed', '2026-07-10', NULL),
    (N'AMBETTER', N'AMBETTER|MARKETPLACE|EXCHANGE', N'Exchange', N'Marketplace Plan', 1, N'System Seed', '2026-07-10', NULL),
    (N'FEDERAL_EMPLOYEE', N'FEP|FEPBLUE|FEDERAL EMPLOYEE|FEHB', N'Federal', N'Federal', 1, N'System Seed', '2026-07-10', N'Added FEHB (Federal Employee Health Benefits) alias'),
    (N'TRICARE', N'TRICARE|CHAMPVA|CHAMPUS|HUMANA MILITARY', N'Federal', N'Federal', 1, N'System Seed', '2026-07-10', N'Military/veteran health coverage'),
    (N'IDPA', N'IDPA', N'Medicaid', N'Medicaid MCO', 1, N'System Seed', '2026-07-10', N'Illinois Department of Public Aid - legacy name still used on some Illinois Medicaid claims/cards'),
    (N'RAILROAD_MEDICARE', N'RAILROAD MEDICARE|RRB|PALMETTO GBA', N'Medicare', N'Federal', 1, N'System Seed', '2026-07-10', N'Railroad Retirement Board Medicare - administered by Palmetto GBA'),
    (N'CHIP', N'CHIP|CHILDREN''S HEALTH INSURANCE', N'Medicaid', N'Medicaid MCO', 1, N'System Seed', '2026-07-10', N'Often billed alongside Medicaid - verify state-specific handling'),
    (N'MEDIGAP', N'MEDIGAP|MEDICARE SUPPLEMENT|MED SUPP', N'Medicare', N'Medicare Supplement', 1, N'System Seed', '2026-07-10', NULL),
    (N'PART_D', N'PART D|\bPDP\b', N'Medicare', N'Medicare MCO', 1, N'System Seed', '2026-07-10', N'Prescription drug plan - confirm in scope for lab billing before relying on this'),
    (N'QHP', N'\bQHP\b|ON EXCHANGE|OFF EXCHANGE', N'Exchange', N'Marketplace Plan', 1, N'System Seed', '2026-07-10', N'Qualified Health Plan'),
    (N'WORKERS_COMP', N'WORKERS COMP|WORKERS'' COMPENSATION|\bWC\b', N'Workers Comp', N'Workers Compensation', 1, N'System Seed', '2026-07-10', N'CAUTION: bare ''WC'' is highly ambiguous - verify context before relying on this alone'),
    (N'AUTO_LIABILITY', N'NO-FAULT|NO FAULT|AUTO LIABILITY|\bPIP\b', N'Auto/Liability', N'Auto Liability', 1, N'System Seed', '2026-07-10', N'PIP = Personal Injury Protection; common in auto no-fault claims'),
    (N'SELF_FUNDED', N'SELF-FUNDED|SELF FUNDED|\bASO\b|SELF-INSURED', N'Commercial', N'TPA', 1, N'System Seed', '2026-07-10', N'Administrative-services-only plan flag'),
    (N'HMO', N'\bHMO\b', NULL, NULL, 1, N'System Seed', '2026-07-10', N'Plan type only'),
    (N'PPO', N'\bPPO\b', NULL, NULL, 1, N'System Seed', '2026-07-10', N'Plan type only'),
    (N'EPO', N'\bEPO\b', NULL, NULL, 1, N'System Seed', '2026-07-10', N'Plan type only'),
    (N'POS', N'\bPOS\b', NULL, NULL, 1, N'System Seed', '2026-07-10', N'Plan type only'),
    (N'POS_II', N'POS II|POS 2', NULL, NULL, 1, N'System Seed', '2026-07-10', N'Plan type only - more specific POS variant, matches before bare POS'),
    (N'HDHP', N'\bHDHP\b', NULL, NULL, 1, N'System Seed', '2026-07-10', N'Plan type only'),
    (N'CDHP', N'\bCDHP\b', NULL, NULL, 1, N'System Seed', '2026-07-10', N'Plan type only'),
    (N'FFS', N'\bFFS\b', NULL, NULL, 1, N'System Seed', '2026-07-10', N'Plan type only - CAUTION: FFS is also broadly used to mean ''fee-for-service'' outside plan-type context, verify'),
    (N'ACO', N'\bACO\b', NULL, NULL, 1, N'System Seed', '2026-07-10', N'Plan type/model only'),
    (N'PFFS', N'\bPFFS\b', NULL, NULL, 1, N'System Seed', '2026-07-10', N'Private Fee-for-Service - Medicare plan type'),
    (N'SNP', N'\bSNP\b', N'Medicare', N'Medicare MCO', 1, N'System Seed', '2026-07-10', NULL);
GO

/* =====================================================================
   5. PlanNetworkTypeCode - network/plan-type codes stripped in Step 1B
   Fixed industry-standard list per the reference doc (Section 4).
   Intentionally excludes marketing names like 'Choice'/'Select' -
   those are handled through PayerAlias instead.
   ===================================================================== */
IF OBJECT_ID(N'dbo.PlanNetworkTypeCode', N'U') IS NOT NULL DROP TABLE dbo.PlanNetworkTypeCode;
GO
CREATE TABLE dbo.PlanNetworkTypeCode (
    CodeId   INT           NOT NULL IDENTITY(1,1) CONSTRAINT PK_PlanNetworkTypeCode PRIMARY KEY,
    Code     NVARCHAR(20)  NOT NULL,
    IsActive BIT           NOT NULL CONSTRAINT DF_PlanNetworkTypeCode_IsActive DEFAULT (1),
    Notes    NVARCHAR(500) NULL
);
GO
CREATE UNIQUE INDEX UX_PlanNetworkTypeCode_Code ON dbo.PlanNetworkTypeCode (Code);
GO
INSERT INTO dbo.PlanNetworkTypeCode (Code, IsActive, Notes) VALUES
    (N'POS II',   1, N'Point of Service II - more specific than POS, strip before bare POS'),
    (N'HDHP/HSA', 1, N'Combined High Deductible Health Plan / HSA designation - strip before bare HDHP or HSA'),
    (N'PPO',      1, N'Preferred Provider Organization'),
    (N'HMO',      1, N'Health Maintenance Organization'),
    (N'EPO',      1, N'Exclusive Provider Organization'),
    (N'POS',      1, N'Point of Service'),
    (N'HDHP',     1, N'High Deductible Health Plan'),
    (N'HSA',      1, N'Health Savings Account plan designation'),
    (N'CDHP',     1, N'Consumer-Driven Health Plan'),
    (N'FFS',      1, N'Fee-for-Service - also used generically outside plan-type context'),
    (N'ACO',      1, N'Accountable Care Organization'),
    (N'SNP',      1, N'Special Needs Plan (Medicare)'),
    (N'PFFS',     1, N'Private Fee-for-Service (Medicare)');
GO

/* =====================================================================
   6. PayerAlias - self-learning (CanonicalName, ResolvedStateCode) ->
      GlobalPayerId cache. Composite unique key on
      (CanonicalName, ResolvedStateCode): CanonicalName alone is NOT safe
      because state-ambiguous names (bare MEDICARE etc.) inherit the
      submitting lab's state and can map to different payers per state.
   Seeded from Lab Insurance Master v1.8.4 (438 confirmed rows).
   NULL handling: SQL Server unique indexes treat NULL as a value, so
   one (name, NULL) row per canonical name is allowed - which is exactly
   the intended semantics for no-state-signal aliases.
   ===================================================================== */
IF OBJECT_ID(N'dbo.PayerAlias', N'U') IS NOT NULL DROP TABLE dbo.PayerAlias;
GO
CREATE TABLE dbo.PayerAlias (
    AliasId           INT            NOT NULL CONSTRAINT PK_PayerAlias PRIMARY KEY,
    CanonicalName     NVARCHAR(200)  NOT NULL,
    ResolvedStateCode CHAR(2)        NULL
        CONSTRAINT FK_PayerAlias_State REFERENCES dbo.USStateCode (StateCode),
    StateSignalSource NVARCHAR(20)   NULL,  -- NameEmbedded / LabState / NULL (no signal)
    GlobalPayerId     INT            NOT NULL,
    ConfirmedBy       NVARCHAR(100)  NOT NULL,
    ConfirmedDate     DATETIME       NOT NULL,
    SourceAction      NVARCHAR(50)   NOT NULL,  -- AutoMap / Approved / ManualMap / Seeded
    ExampleRawName    NVARCHAR(200)  NULL,
    SourceRowCount    INT            NULL
);
GO
CREATE UNIQUE INDEX UX_PayerAlias_Name_State
    ON dbo.PayerAlias (CanonicalName, ResolvedStateCode);
GO
/* Enable if/when Payer Policy Insurance Master exists with this name:
ALTER TABLE dbo.PayerAlias ADD CONSTRAINT FK_PayerAlias_GlobalPayer
    FOREIGN KEY (GlobalPayerId) REFERENCES dbo.PayerPolicyInsuranceMaster (GlobalPayerId);
*/

INSERT INTO dbo.PayerAlias (AliasId, CanonicalName, ResolvedStateCode, StateSignalSource, GlobalPayerId, ConfirmedBy, ConfirmedDate, SourceAction, ExampleRawName, SourceRowCount) VALUES
    (1, N'ABS SMART HEALTH BCBS MI', 'MI', N'NameEmbedded', 1045, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'ABS - SMART HEALTH - BCBS MI (PPO)', 1),
    (2, N'ABSOLUTE TOTAL CARE', 'MS', N'LabState', 1000, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'Absolute Total Care', 1),
    (3, N'ABSOLUTE TOTAL CARE ABSO1', 'FL', N'LabState', 1000, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'ABSOLUTE TOTAL CARE - ABSO1', 1),
    (4, N'ABSOLUTE TOTAL CARE ABTC', NULL, NULL, 1000, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'ABSOLUTE TOTAL CARE - ABTC', 1),
    (5, N'AETNA', 'IL', N'LabState', 1001, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'AETNA', 1),
    (6, N'AETNA', 'MI', N'LabState', 1001, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'AETNA (POS)', 3),
    (7, N'AETNA', 'MS', N'LabState', 1001, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'Aetna', 1),
    (8, N'AETNA', 'TX', N'LabState', 1001, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'AETNA', 2),
    (9, N'AETNA', NULL, NULL, 1001, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'Aetna', 4),
    (10, N'AETNA AETNA', 'AL', N'LabState', 1001, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'AETNA - AETNA', 1),
    (11, N'AETNA AETNA', 'CO', N'LabState', 1001, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'AETNA - AETNA', 1),
    (12, N'AETNA AETNA', NULL, NULL, 1001, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'AETNA - AETNA', 2),
    (13, N'AETNA AETNA LIFE INSURANCE COMPANY', 'MI', N'LabState', 1001, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'AETNA - AETNA LIFE INSURANCE COMPANY', 1),
    (14, N'AETNA CHOICE', 'MI', N'LabState', 1001, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'AETNA - CHOICE (POS II)', 2),
    (15, N'AETNA CHOICE PLUS', 'MI', N'LabState', 1001, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'AETNA CHOICE PLUS', 1),
    (16, N'AETNA SELECT OPEN ACCESS', 'MI', N'LabState', 1001, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'AETNA SELECT OPEN ACCESS', 1),
    (17, N'AETNA SENIOR SUPPLEMENTAL INSURANCE', 'MI', N'LabState', 1001, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'AETNA SENIOR SUPPLEMENTAL INSURANCE', 1),
    (18, N'AETNA SIGNATURE ADMINISTRATORS GEHA', 'MI', N'LabState', 1001, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'AETNA SIGNATURE ADMINISTRATORS - GEHA', 1),
    (19, N'ALABAMA MEDICAID', 'AL', N'NameEmbedded', 1119, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'ALABAMA MEDICAID', 1),
    (20, N'AMBETTER', 'IL', N'LabState', 1009, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'AMBETTER', 1),
    (21, N'AMBETTER FROM ALABAMA AMAL', 'AL', N'NameEmbedded', 1003, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'AMBETTER FROM ALABAMA - AMAL', 2),
    (22, N'AMBETTER FROM ARIZONA COMPLETE HEALTH', 'AZ', N'NameEmbedded', 1017, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'AMBETTER FROM ARIZONA COMPLETE HEALTH', 2),
    (23, N'AMBETTER FROM BUCKEYE COMMUNITY HEALTH PLAN', 'MI', N'LabState', 1063, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'AMBETTER FROM BUCKEYE COMMUNITY HEALTH PLAN', 1),
    (24, N'AMBETTER FROM BUCKEYE HEALTH P AMBE6', 'FL', N'LabState', 1063, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'AMBETTER FROM BUCKEYE HEALTH P - AMBE6', 1),
    (25, N'AMBETTER FROM PEACH STATE HEALTH', 'FL', N'LabState', 1213, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'AMBETTER FROM PEACH STATE HEALTH', 1),
    (26, N'AMBETTER FROM PEACH STATE HEALTH AMBGA', 'AL', N'LabState', 1213, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'AMBETTER FROM PEACH STATE HEALTH - AMBGA', 1),
    (27, N'AMBETTER FROM PEACH STATE HEALTH AMBGA', 'CO', N'LabState', 1213, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'AMBETTER FROM PEACH STATE HEALTH - AMBGA', 1),
    (28, N'AMBETTER MARKET PLACE', 'IL', N'LabState', 1002, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'Ambetter (Market Place)', 1),
    (29, N'AMBETTER OF ALABAMA', 'AL', N'NameEmbedded', 1003, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'AMBETTER OF ALABAMA', 1),
    (30, N'AMBETTER OF ILLINOIS', 'IL', N'NameEmbedded', 1009, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'Ambetter of Illinois', 1),
    (31, N'AMBETTER OF NORTH CAROLINA', 'NC', N'NameEmbedded', 1010, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'AMBETTER OF NORTH CAROLINA', 1),
    (32, N'AMBETTER OF TENNESSEE AMTN', 'TN', N'NameEmbedded', 1007, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'AMBETTER OF TENNESSEE - AMTN', 2),
    (33, N'AMBETTER PEACH STATE HEALTH PLAN AMB02', 'FL', N'LabState', 1213, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'AMBETTER PEACH STATE HEALTH PLAN - AMB02', 1),
    (34, N'AMBETTER PEACH STATE HEALTH PLAN APSHP', NULL, NULL, 1213, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'AMBETTER PEACH STATE HEALTH PLAN - APSHP', 1),
    (35, N'AMBETTEROF ILLINOIS', 'IL', N'NameEmbedded', 1009, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'Ambetterof Illinois', 1),
    (36, N'AMERIGROUP WELLPOINT AZ IA TN TX WA AMGWP', 'AZ', N'NameEmbedded', 1170, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'AMERIGROUP(WELLPOINT)AZ,IA,TN,TX,WA - AMGWP', 1),
    (37, N'ANTHEM ANTHEM BCBS OF OHIO', 'OH', N'NameEmbedded', 1015, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'ANTHEM - ANTHEM BCBS OF OHIO', 1),
    (38, N'ANTHEM BC/BS', 'MI', N'LabState', 1045, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'ANTHEM BC/BS', 1),
    (39, N'ANTHEM BCBS NY', 'NY', N'NameEmbedded', 1027, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'ANTHEM BCBS-NY', 2),
    (40, N'ANTHEM BCBS OF KENTUCKY', 'KY', N'NameEmbedded', 1014, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'Anthem BCBS of Kentucky', 1),
    (41, N'ANTHEM BCBS OH IN KY', 'OH', N'NameEmbedded', 1015, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'ANTHEM BCBS - OH, IN, KY', 1),
    (42, N'ANTHEM BCBS OHIO FEP', 'OH', N'NameEmbedded', 1015, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'ANTHEM BCBS OHIO FEP', 1),
    (43, N'ANTHEM BLUE CROSS', 'MI', N'LabState', 1045, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'Anthem Blue Cross', 1),
    (44, N'ANTHEM BLUE CROSS BLUE SHIELD', 'MI', N'LabState', 1045, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'ANTHEM BLUE CROSS BLUE SHIELD', 1),
    (45, N'ANTHEM BLUE CROSS BLUE SHIELD OF KY', 'KY', N'NameEmbedded', 1014, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'ANTHEM BLUE CROSS BLUE SHIELD OF KY', 1),
    (46, N'ANTHEM BLUE CROSS BLUE SHIELD OF OH', 'OH', N'NameEmbedded', 1015, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'ANTHEM BLUE CROSS BLUE SHIELD OF OH', 1),
    (47, N'ANTHEM BLUE CROSS BLUE SHIELD OF OH CENTRAL', 'OH', N'NameEmbedded', 1015, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'ANTHEM BLUE CROSS BLUE SHIELD OF OH (CENTRAL)', 1),
    (48, N'ANTHEM BLUE CROSS BLUE SHIELD OF VA', 'VA', N'NameEmbedded', 1029, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'ANTHEM BLUE CROSS BLUE SHIELD OF VA', 1),
    (49, N'ANTHEM BLUE CROSS CA ANT05', 'CA', N'NameEmbedded', 1011, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'ANTHEM BLUE CROSS CA - ANT05', 1),
    (50, N'ANTHEM BLUE CROSS CALIFORNIA', 'CA', N'NameEmbedded', 1011, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'ANTHEM BLUE CROSS CALIFORNIA', 1),
    (51, N'ANTHEM CA ANT05', 'CA', N'NameEmbedded', 1011, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'ANTHEM (CA) - ANT05', 3),
    (52, N'ANTHEM CO ANTHCO', 'CO', N'NameEmbedded', 1012, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'ANTHEM CO - ANTHCO', 1),
    (53, N'ANTHEM CT ANTH2', 'CT', N'NameEmbedded', 1005, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'ANTHEM (CT) - ANTH2', 1),
    (54, N'ANTHEM GA ANTH2', 'GA', N'NameEmbedded', 1013, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'ANTHEM GA - ANTH2', 3),
    (55, N'ANTHEM IN ANIN', 'IN', N'NameEmbedded', 1016, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'ANTHEM (IN) - ANIN', 2),
    (56, N'ANTHEM KENTUCKY ANKY', 'KY', N'NameEmbedded', 1014, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'ANTHEM KENTUCKY - ANKY', 1),
    (57, N'ANTHEM KY ANKY', 'KY', N'NameEmbedded', 1014, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'ANTHEM KY - ANKY', 1),
    (58, N'ANTHEM NEVADA ANTHNV', 'NV', N'NameEmbedded', 1023, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'ANTHEM-NEVADA - ANTHNV', 1),
    (59, N'ANTHEM OF CO ANTHCO', 'CO', N'NameEmbedded', 1012, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'ANTHEM OF CO - ANTHCO', 1),
    (60, N'ANTHEM OH ANTHOH', 'OH', N'NameEmbedded', 1015, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'ANTHEM OH  - ANTHOH', 2),
    (61, N'ANTHEM SE VA ANTVA', 'VA', N'NameEmbedded', 1029, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'ANTHEM SE (VA) - ANTVA', 2),
    (62, N'ANTHEM/BCBS OF IN ANIN', 'IN', N'NameEmbedded', 1016, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'ANTHEM/BCBS OF IN - ANIN', 1),
    (63, N'ARIZONA COMPLETE HEALTH ACH', 'AZ', N'NameEmbedded', 1017, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'ARIZONA COMPLETE HEALTH - ACH', 2),
    (64, N'BCBS', 'MI', N'LabState', 1045, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS', 1),
    (65, N'BCBS AL BCBSAL', 'AL', N'NameEmbedded', 1032, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-AL - BCBSAL', 3),
    (66, N'BCBS ALABAMA', 'AL', N'NameEmbedded', 1032, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS- Alabama', 1),
    (67, N'BCBS ANTHEM LAKE HURON MEDICAL CENTER', 'MI', N'LabState', 1045, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS ANTHEM- LAKE HURON MEDICAL CENTER', 1),
    (68, N'BCBS AR BCBSAR', 'AR', N'NameEmbedded', 1033, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-AR - BCBSAR', 2),
    (69, N'BCBS ARIZONA', 'AZ', N'NameEmbedded', 1024, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS ARIZONA', 1),
    (70, N'BCBS AZ', 'AZ', N'NameEmbedded', 1024, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS AZ', 1),
    (71, N'BCBS AZ BCBSAZ', 'AZ', N'NameEmbedded', 1024, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-AZ - BCBSAZ', 2),
    (72, N'BCBS BLUE CROSS AND BLUE SHIELD OF MICHIGAN', 'MI', N'NameEmbedded', 1045, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS - BLUE CROSS AND BLUE SHIELD OF MICHIGAN', 1),
    (73, N'BCBS BLUE CROSS COMPLETE', 'MI', N'LabState', 1122, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS - BLUE CROSS COMPLETE', 1),
    (74, N'BCBS CA BLUE CROSS BCB16', 'CA', N'NameEmbedded', 1011, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS CA(BLUE CROSS) - BCB16', 1),
    (75, N'BCBS CA BLUE SHIELD', 'CA', N'NameEmbedded', 1011, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS CA (BLUE SHIELD)', 1),
    (76, N'BCBS CA CAL02', 'CA', N'NameEmbedded', 1011, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS- CA - CAL02', 2),
    (77, N'BCBS CO ANTHEM BCBS OF CO', 'CO', N'NameEmbedded', 1012, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-CO: ANTHEM BCBS OF CO (PPO)', 1),
    (78, N'BCBS COMMUNITY', 'IL', N'LabState', 1040, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS COMMUNITY', 1),
    (79, N'BCBS COMMUNITY MMAI', 'IL', N'LabState', 1040, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS COMMUNITY MMAI', 1),
    (80, N'BCBS COMMUNITY MMAI XOG', 'IL', N'LabState', 1040, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS COMMUNITY MMAI (XOG)', 1),
    (81, N'BCBS COMMUNITY MMCP XXL', 'IL', N'LabState', 1040, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS COMMUNITY MMCP (XXL)', 1),
    (82, N'BCBS DE HIGHMARK BLUE CROSS BLUE SHIELD OF DELAWARE', 'DE', N'NameEmbedded', 1079, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-DE: HIGHMARK BLUE CROSS BLUE SHIELD OF DELAWARE', 1),
    (83, N'BCBS FL', 'FL', N'NameEmbedded', 1034, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS FL', 1),
    (84, N'BCBS FL BCBSFL', 'FL', N'NameEmbedded', 1034, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-FL - BCBSFL', 4),
    (85, N'BCBS FL BLUE OPTIONS', 'FL', N'NameEmbedded', 1034, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-FL: BLUE OPTIONS (PPO)', 1),
    (86, N'BCBS FL FLO01', 'FL', N'NameEmbedded', 1034, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS FL - FLO01', 1),
    (87, N'BCBS GA ANTHEM BCBS', 'GA', N'NameEmbedded', 1013, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-GA: ANTHEM BCBS (PPO)', 1),
    (88, N'BCBS GA BCBSGA', 'GA', N'NameEmbedded', 1013, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS - GA - BCBSGA', 1),
    (89, N'BCBS GA GEO03', 'GA', N'NameEmbedded', 1013, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS GA - GEO03', 1),
    (90, N'BCBS ID', 'ID', N'NameEmbedded', 1062, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS ID', 1),
    (91, N'BCBS ID BCB12', 'ID', N'NameEmbedded', 1062, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS ID - BCB12', 1),
    (92, N'BCBS ID REGENCE', 'ID', N'NameEmbedded', 1062, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS ID(REGENCE)', 1),
    (93, N'BCBS ID REGENCE BCB22', 'ID', N'NameEmbedded', 1062, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS ID(REGENCE) - BCB22', 1),
    (94, N'BCBS IL', 'IL', N'NameEmbedded', 1039, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-IL: (PPO)', 1),
    (95, N'BCBS IL BCBSIL', 'IL', N'NameEmbedded', 1039, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-IL - BCBSIL', 2),
    (96, N'BCBS IL BLUE CHOICE SELECT', 'IL', N'NameEmbedded', 1039, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS IL BLUE CHOICE SELECT', 1),
    (97, N'BCBS IN', 'IN', N'NameEmbedded', 1016, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS IN', 1),
    (98, N'BCBS IN BCB11', 'IN', N'NameEmbedded', 1016, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS IN - BCB11', 1),
    (99, N'BCBS KANSAS CITY BCBSKC', 'KS', N'NameEmbedded', 1042, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS- KANSAS CITY - BCBSKC', 1),
    (100, N'BCBS KS BCBSKS', 'KS', N'NameEmbedded', 1042, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-KS - BCBSKS', 1),
    (101, N'BCBS KY', 'KY', N'NameEmbedded', 1014, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS KY', 1),
    (102, N'BCBS KY ANT05', 'KY', N'NameEmbedded', 1014, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS KY - ANT05', 1),
    (103, N'BCBS LA BCBS4', 'LA', N'NameEmbedded', 1025, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS LA - BCBS4', 1),
    (104, N'BCBS LA BCBSLA', 'LA', N'NameEmbedded', 1025, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-LA - BCBSLA', 2),
    (105, N'BCBS LA LOUISIANA', 'LA', N'NameEmbedded', 1025, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS LA(LOUISIANA)', 2),
    (106, N'BCBS MI', 'MI', N'NameEmbedded', 1045, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS MI', 4),
    (107, N'BCBS MI BCBS OF MI', 'MI', N'NameEmbedded', 1045, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-MI: BCBS OF MI', 1),
    (108, N'BCBS MI BCBS OF MI MESSA BLUE CHOICE', 'MI', N'NameEmbedded', 1045, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-MI:  BCBS OF MI - MESSA BLUE CHOICE (POS)', 1),
    (109, N'BCBS MI BCBSMI', 'MI', N'NameEmbedded', 1045, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-MI - BCBSMI', 4),
    (110, N'BCBS MI BLUE CROSS COMPLETE MEDICAID REPLACEMENT', 'MI', N'NameEmbedded', 1122, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-MI BLUE CROSS COMPLETE (MEDICAID REPLACEMENT - HMO)', 1),
    (111, N'BCBS MI NASCO INDEMNITY', 'MI', N'NameEmbedded', 1045, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-MI: NASCO (INDEMNITY)', 1),
    (112, N'BCBS MISSISSIPPI', 'MS', N'NameEmbedded', 1028, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS  Mississippi', 1),
    (113, N'BCBS MN', 'MN', N'NameEmbedded', 1046, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS MN', 1),
    (114, N'BCBS MN BCB15', 'MN', N'NameEmbedded', 1046, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS MN - BCB15', 1),
    (115, N'BCBS MN BCBSMN', 'MN', N'NameEmbedded', 1046, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-MN - BCBSMN', 1),
    (116, N'BCBS MO', 'MO', N'NameEmbedded', 1022, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS MO', 1),
    (117, N'BCBS MO BCBSMO', 'MO', N'NameEmbedded', 1022, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-MO - BCBSMO', 3),
    (118, N'BCBS MS BCBS5', 'MS', N'NameEmbedded', 1028, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS MS - BCBS5', 1),
    (119, N'BCBS MS BCBSMS', 'MS', N'NameEmbedded', 1028, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-MS - BCBSMS', 2),
    (120, N'BCBS MS MISSISSIPPI', 'MS', N'NameEmbedded', 1028, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS MS(MISSISSIPPI)', 2),
    (121, N'BCBS MT', 'MT', N'NameEmbedded', 1048, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS MT', 1),
    (122, N'BCBS MT BCBSMT', 'MT', N'NameEmbedded', 1048, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-MT - BCBSMT', 1),
    (123, N'BCBS NC', 'NC', N'NameEmbedded', 1049, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS NC', 1),
    (124, N'BCBS NC BCBS9', 'NC', N'NameEmbedded', 1049, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS NC - BCBS9', 1),
    (125, N'BCBS NC BCBSNC', 'NC', N'NameEmbedded', 1049, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-NC - BCBSNC', 2),
    (126, N'BCBS NE', 'NE', N'NameEmbedded', 1050, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS NE', 1),
    (127, N'BCBS NE BCBSNE', 'NE', N'NameEmbedded', 1050, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-NE - BCBSNE', 1),
    (128, N'BCBS NEW MEXICO', 'NM', N'NameEmbedded', 1052, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS New Mexico', 1),
    (129, N'BCBS NM', 'NM', N'NameEmbedded', 1052, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS NM', 1),
    (130, N'BCBS NM BCB13', 'NM', N'NameEmbedded', 1052, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS NM - BCB13', 1),
    (131, N'BCBS NV', 'NV', N'NameEmbedded', 1023, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS NV', 1),
    (132, N'BCBS OF ALABAMA', 'AL', N'NameEmbedded', 1032, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS OF ALABAMA', 1),
    (133, N'BCBS OF CALIFORNIA', 'CA', N'NameEmbedded', 1011, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS OF CALIFORNIA', 1),
    (134, N'BCBS OF FLORIDA', 'FL', N'NameEmbedded', 1034, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS of Florida', 1),
    (135, N'BCBS OF GEORGIA', 'GA', N'NameEmbedded', 1013, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS of Georgia', 1),
    (136, N'BCBS OF IL', 'IL', N'NameEmbedded', 1039, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS OF IL', 1),
    (137, N'BCBS OF IL OFFICE USE', 'IL', N'NameEmbedded', 1039, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS OF IL PPO (OFFICE USE)', 1),
    (138, N'BCBS OF MI', 'MI', N'NameEmbedded', 1045, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS OF MI', 1),
    (139, N'BCBS OF MICHIGAN', 'MI', N'NameEmbedded', 1045, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS OF MICHIGAN', 1),
    (140, N'BCBS OF TEXAS', 'TX', N'NameEmbedded', 1059, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS of Texas', 1),
    (141, N'BCBS OH', 'OH', N'NameEmbedded', 1015, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS OH', 1),
    (142, N'BCBS OH ANTHEM BCBS', 'OH', N'NameEmbedded', 1015, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-OH: ANTHEM BCBS (PPO)', 1),
    (143, N'BCBS OK', 'OK', N'NameEmbedded', 1056, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS OK', 1),
    (144, N'BCBS OR', 'OR', N'NameEmbedded', 1154, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS OR', 1),
    (145, N'BCBS PA', 'PA', N'NameEmbedded', 1080, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS PA', 1),
    (146, N'BCBS PA BCBS1', 'PA', N'NameEmbedded', 1080, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS PA - BCBS1', 1),
    (147, N'BCBS PA INDEPENDENCE BLUE CROSS', 'PA', N'NameEmbedded', 1080, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-PA INDEPENDENCE BLUE CROSS (PPO)', 1),
    (148, N'BCBS SC', 'SC', N'NameEmbedded', 1057, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS SC', 2),
    (149, N'BCBS SC BCBS2', 'SC', N'NameEmbedded', 1057, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS SC - BCBS2', 1),
    (150, N'BCBS SC BCBSSC', 'SC', N'NameEmbedded', 1057, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-SC - BCBSSC', 2),
    (151, N'BCBS SD BCBSSD', 'SD', N'NameEmbedded', 1169, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-SD - BCBSSD', 1),
    (152, N'BCBS SIMPLY BLUE', 'MI', N'LabState', 1059, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS SIMPLY BLUE PPO', 1),
    (153, N'BCBS SIMPLY BLUE TX', 'TX', N'NameEmbedded', 1059, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS SIMPLY BLUE PPO - TX', 1),
    (154, N'BCBS STATE HEALTH PLAN', 'MI', N'LabState', 1045, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS PPO STATE HEALTH PLAN', 1),
    (155, N'BCBS TN', 'TN', N'NameEmbedded', 1058, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-TN: (PPO)', 1),
    (156, N'BCBS TN BCB21', 'TN', N'NameEmbedded', 1058, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS TN - BCB21', 1),
    (157, N'BCBS TN BCBSTN', 'TN', N'NameEmbedded', 1058, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-TN - BCBSTN', 1),
    (158, N'BCBS TX', 'TX', N'NameEmbedded', 1059, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS TX', 1),
    (159, N'BCBS TX BCB10', 'TX', N'NameEmbedded', 1059, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS TX - BCB10', 1),
    (160, N'BCBS TX BCBS OF TX', 'TX', N'NameEmbedded', 1059, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-TX: BCBS OF TX (PPO)', 1),
    (161, N'BCBS TX BCBS TX', 'TX', N'NameEmbedded', 1059, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-TX: BCBS TX', 1),
    (162, N'BCBS TX BCBSTX', 'TX', N'NameEmbedded', 1059, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-TX - BCBSTX', 3),
    (163, N'BCBS UT', 'UT', N'NameEmbedded', 1155, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-UT (PPO)', 1),
    (164, N'BCBS VA', 'VA', N'NameEmbedded', 1029, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS VA', 1),
    (165, N'BCBS VA ANTHEM BCBS', 'VA', N'NameEmbedded', 1029, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-VA: ANTHEM BCBS (PPO)', 1),
    (166, N'BCBS VA BCB24', 'VA', N'NameEmbedded', 1029, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS VA - BCB24', 1),
    (167, N'BCBS WA', 'WA', N'NameEmbedded', 1157, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS WA', 1),
    (168, N'BCBS WA PREMERA BLUE CROSS BLUE SHIELD', 'WA', N'NameEmbedded', 1157, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS-WA: PREMERA BLUE CROSS BLUE SHIELD (PPO)', 1),
    (169, N'BCBS WA REGENCE', 'WA', N'NameEmbedded', 1157, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS WA - REGENCE.', 2),
    (170, N'BCBS WA/AK PREMERA', 'WA', N'NameEmbedded', 1157, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBS WA/AK - PREMERA', 1),
    (171, N'BCBSM', 'MI', N'LabState', 1045, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BCBSM', 1),
    (172, N'BLUE CROSS AND BLUE SHIELD', 'MI', N'LabState', 1045, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE CROSS AND BLUE SHIELD', 1),
    (173, N'BLUE CROSS AND BLUE SHIELD MI MEDICAID COMPLETE', 'MI', N'NameEmbedded', 1122, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE CROSS AND BLUE SHIELD MI MEDICAID COMPLETE', 1),
    (174, N'BLUE CROSS AND BLUE SHIELD OF MICHIGAN', 'MI', N'NameEmbedded', 1045, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE CROSS AND BLUE SHIELD OF MICHIGAN', 1),
    (175, N'BLUE CROSS BLUE SHEILD MICHIGAN', 'MI', N'NameEmbedded', 1045, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'Blue Cross Blue Sheild Michigan', 1),
    (176, N'BLUE CROSS BLUE SHIELD', 'MI', N'LabState', 1045, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE CROSS BLUE SHIELD', 2),
    (177, N'BLUE CROSS BLUE SHIELD BLUE CARD', 'MI', N'LabState', 1045, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE CROSS BLUE SHIELD (BLUE CARD PPO)', 1),
    (178, N'BLUE CROSS BLUE SHIELD ILLINOIS', 'IL', N'NameEmbedded', 1039, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE CROSS BLUE SHIELD ILLINOIS', 1),
    (179, N'BLUE CROSS BLUE SHIELD MI', 'MI', N'NameEmbedded', 1045, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE CROSS BLUE SHIELD MI', 1),
    (180, N'BLUE CROSS BLUE SHIELD MICHIGAN', 'MI', N'NameEmbedded', 1045, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE CROSS BLUE SHIELD MICHIGAN', 1),
    (181, N'BLUE CROSS BLUE SHIELD OF ALABAMA', 'AL', N'NameEmbedded', 1032, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE CROSS BLUE SHIELD OF ALABAMA', 1),
    (182, N'BLUE CROSS BLUE SHIELD OF GA', 'GA', N'NameEmbedded', 1013, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE CROSS BLUE SHIELD OF GA', 1),
    (183, N'BLUE CROSS BLUE SHIELD OF GEORGIA', 'GA', N'NameEmbedded', 1013, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE CROSS BLUE SHIELD OF GEORGIA', 1),
    (184, N'BLUE CROSS BLUE SHIELD OF KANSAS BCBSKS', 'KS', N'NameEmbedded', 1042, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE CROSS BLUE SHIELD OF KANSAS - BCBSKS', 1),
    (185, N'BLUE CROSS BLUE SHIELD OF LOUISIANA', 'LA', N'NameEmbedded', 1025, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'Blue Cross Blue Shield Of Louisiana', 2),
    (186, N'BLUE CROSS BLUE SHIELD OF MI', 'MI', N'NameEmbedded', 1045, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE CROSS BLUE SHIELD OF MI', 1),
    (187, N'BLUE CROSS BLUE SHIELD OF MICHIGAN', 'MI', N'NameEmbedded', 1045, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE CROSS BLUE SHIELD OF MICHIGAN', 1),
    (188, N'BLUE CROSS BLUE SHIELD OF MN', 'MN', N'NameEmbedded', 1046, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE CROSS BLUE SHIELD OF MN', 1),
    (189, N'BLUE CROSS BLUE SHIELD OF NC', 'NC', N'NameEmbedded', 1049, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE CROSS BLUE SHIELD OF NC', 1),
    (190, N'BLUE CROSS BLUE SHIELD OF SC', 'SC', N'NameEmbedded', 1057, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE CROSS BLUE SHIELD OF SC', 1),
    (191, N'BLUE CROSS BLUE SHIELD OF SOUTH CAROLINA', 'SC', N'NameEmbedded', 1057, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE CROSS BLUE SHIELD OF SOUTH CAROLINA', 1),
    (192, N'BLUE CROSS BLUE SHIELD OF TENNESEE', 'MI', N'LabState', 1058, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE CROSS BLUE SHIELD OF TENNESEE', 1),
    (193, N'BLUE CROSS BLUE SHIELD OF TEXAS', 'TX', N'NameEmbedded', 1059, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE CROSS BLUE SHIELD OF TEXAS', 1),
    (194, N'BLUE CROSS BLUE SHIELD OF TEXAS HCSC', 'TX', N'NameEmbedded', 1059, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE CROSS & BLUE SHIELD OF TEXAS (hcsc)', 1),
    (195, N'BLUE CROSS BLUE SHIELD OF TN CHATTANOOGA', 'TN', N'NameEmbedded', 1058, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE CROSS BLUE SHIELD OF TN (CHATTANOOGA)', 1),
    (196, N'BLUE CROSS BLUE SHIELD OF TX', 'TX', N'NameEmbedded', 1059, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE CROSS BLUE SHIELD OF TX', 1),
    (197, N'BLUE CROSS BLUS SHIELD', 'MI', N'LabState', 1045, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE CROSS BLUS SHIELD PPO', 1),
    (198, N'BLUE CROSS CA ANTHEM BLUE CROSS', 'CA', N'NameEmbedded', 1011, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE CROSS-CA: ANTHEM BLUE CROSS (PPO)', 1),
    (199, N'BLUE CROSS COMPLETE', 'MI', N'LabState', 1122, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE CROSS COMPLETE', 1),
    (200, N'BLUE CROSS COMPLETE OF MI', 'MI', N'NameEmbedded', 1122, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE CROSS COMPLETE OF MI', 1);
GO

INSERT INTO dbo.PayerAlias (AliasId, CanonicalName, ResolvedStateCode, StateSignalSource, GlobalPayerId, ConfirmedBy, ConfirmedDate, SourceAction, ExampleRawName, SourceRowCount) VALUES
    (201, N'BLUE CROSS COMPLETE OF MICHIGAN', 'MI', N'NameEmbedded', 1122, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE CROSS COMPLETE OF MICHIGAN', 1),
    (202, N'BLUE CROSS OF ID BCBSID', 'ID', N'NameEmbedded', 1062, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE CROSS OF ID - BCBSID', 1),
    (203, N'BLUE CROSS OF TX', 'TX', N'NameEmbedded', 1059, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE CROSS OF TX', 1),
    (204, N'BLUE CROSS T BLUE SHIELD OF MICHIGAN', 'MI', N'NameEmbedded', 1045, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE CROSS \T\ BLUE SHIELD OF MICHIGAN', 1),
    (205, N'BLUE SHIELD CA BLUE SHIELD OF CA', 'CA', N'NameEmbedded', 1011, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE SHIELD-CA: BLUE SHIELD OF CA', 1),
    (206, N'BLUE SHIELD OF CALIFORNIA', 'CA', N'NameEmbedded', 1011, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'Blue Shield of California HSA', 1),
    (207, N'BLUE SHIELD OF CALIFORNIA BSCA', 'CA', N'NameEmbedded', 1011, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE SHIELD OF CALIFORNIA - BSCA', 1),
    (208, N'BLUE SHIELD PROMISE HEALTH PLAN CA BCBCPR', 'CA', N'NameEmbedded', 1011, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE SHIELD PROMISE HEALTH PLAN CA - BCBCPR', 1),
    (209, N'BLUE SHIELD PROMISE HEALTH PLAN CA BCBSPR', 'CA', N'NameEmbedded', 1011, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BLUE SHIELD PROMISE HEALTH PLAN CA - BCBSPR', 1),
    (210, N'BUCKEYE COMMUNITY HEALTH', 'MI', N'LabState', 1063, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BUCKEYE COMMUNITY HEALTH', 1),
    (211, N'BUCKEYE COMMUNITY HEALTH BCH', 'CO', N'LabState', 1063, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BUCKEYE COMMUNITY HEALTH - BCH', 1),
    (212, N'BUCKEYE COMMUNITY HEALTH PLAN BUCK1', 'FL', N'LabState', 1063, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BUCKEYE COMMUNITY HEALTH PLAN - BUCK1', 1),
    (213, N'BUCKEYE HEALTH PLAN', 'MI', N'LabState', 1063, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'BUCKEYE HEALTH PLAN', 1),
    (214, N'CARESOURCE GA', 'GA', N'NameEmbedded', 1065, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CARESOURCE GA', 1),
    (215, N'CARESOURCE GA CSGA', 'GA', N'NameEmbedded', 1065, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CARESOURCE - GA - CSGA', 1),
    (216, N'CARESOURCE GEORGIA CAGA', 'GA', N'NameEmbedded', 1065, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CARESOURCE GEORGIA - CAGA', 1),
    (217, N'CARESOURCE MCD OHIO', 'OH', N'NameEmbedded', 1036, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CARESOURCE MCD OHIO', 1),
    (218, N'CARESOURCE MICHIGAN CSMI', 'MI', N'NameEmbedded', 1077, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CARESOURCE MICHIGAN - CSMI', 1),
    (219, N'CARESOURCE OF GA CARE1', 'GA', N'NameEmbedded', 1065, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CARESOURCE OF GA - CARE1', 1),
    (220, N'CARESOURCE OF GEORGIA CAGA', 'GA', N'NameEmbedded', 1065, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CARESOURCE OF GEORGIA - CAGA', 1),
    (221, N'CARESOURCE OF OH', 'OH', N'NameEmbedded', 1036, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CARESOURCE OF OH', 1),
    (222, N'CARESOURCE OF OH CARE4', 'OH', N'NameEmbedded', 1036, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CARESOURCE OF OH - CARE4', 1),
    (223, N'CARESOURCE OH', 'OH', N'NameEmbedded', 1036, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CARESOURCE OH', 1),
    (224, N'CARESOURCE OH CSOH', 'OH', N'NameEmbedded', 1036, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CARESOURCE - OH - CSOH', 1),
    (225, N'CARESOURCE OH DOS ON OR AFTER 02/01/2023 MEDICAID REPLACE', 'OH', N'NameEmbedded', 1036, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CARESOURCE-OH - DOS ON OR AFTER 02/01/2023 (MEDICAID REPLACE', 1),
    (226, N'CARESOURCE OH MEDICAID', 'OH', N'NameEmbedded', 1036, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CARESOURCE OH MEDICAID', 1),
    (227, N'CARESOURCE OH MEDICAID DOS ON OR AFTER 02012023', 'OH', N'NameEmbedded', 1036, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CareSource OH Medicaid DOS on or after 02012023', 1),
    (228, N'CARESOURCE OHIO CASOH', 'OH', N'NameEmbedded', 1036, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CARESOURCE OHIO - CASOH', 2),
    (229, N'CARESOURCE OHIO CSOH', 'OH', N'NameEmbedded', 1036, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CARESOURCE OHIO - CSOH', 1),
    (230, N'CARESOURCE OHIO MEDICAID', 'OH', N'NameEmbedded', 1036, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CARESOURCE OHIO MEDICAID', 1),
    (231, N'CHRISTUS HEALTH PLAN', 'IL', N'LabState', 1072, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'Christus Health Plan', 1),
    (232, N'CIGNA', 'IL', N'LabState', 1038, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CIGNA', 2),
    (233, N'CIGNA', 'MI', N'LabState', 1038, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CIGNA PPO', 2),
    (234, N'CIGNA', 'MS', N'LabState', 1038, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'Cigna', 1),
    (235, N'CIGNA', 'TX', N'LabState', 1038, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CIGNA', 1),
    (236, N'CIGNA BEHAVIORAL HEALTH CBHE', NULL, NULL, 1038, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CIGNA BEHAVIORAL HEALTH - CBHE', 1),
    (237, N'CIGNA CIG09', 'FL', N'LabState', 1038, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CIGNA - CIG09', 1),
    (238, N'CIGNA CIGNA', 'AL', N'LabState', 1038, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CIGNA - CIGNA', 1),
    (239, N'CIGNA CIGNA', 'CO', N'LabState', 1038, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CIGNA - CIGNA', 1),
    (240, N'CIGNA CIGNA', 'TX', N'LabState', 1038, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CIGNA - CIGNA', 1),
    (241, N'CIGNA CIGNA', NULL, NULL, 1038, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CIGNA - CIGNA', 3),
    (242, N'CIGNA CORESOURCE', 'MI', N'LabState', 1038, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CIGNA - CORESOURCE (PPO)', 1),
    (243, N'CIGNA HAP MI', 'MI', N'NameEmbedded', 1038, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CIGNA - HAP - MI', 1),
    (244, N'CIGNA HEALTH AND LIFE INSURANCE CHLIC', NULL, NULL, 1038, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CIGNA HEALTH AND LIFE INSURANCE - CHLIC', 1),
    (245, N'CIGNA HEALTH AND LIFE INSURANCE COM CHLIC', 'CO', N'LabState', 1038, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CIGNA HEALTH AND LIFE INSURANCE COM - CHLIC', 1),
    (246, N'CIGNA HEALTHCARE', 'MI', N'LabState', 1038, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CIGNA HEALTHCARE (HMO)', 3),
    (247, N'CIGNA HEALTHCARE NALC HEALTH BENEFITS PLAN OPEN ACCESS P', 'MI', N'LabState', 1038, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CIGNA HEALTHCARE - NALC HEALTH BENEFITS PLAN - OPEN ACCESS P', 1),
    (248, N'CIGNA MED CLAIMS', 'IL', N'LabState', 1038, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CIGNA MED CLAIMS', 1),
    (249, N'CIGNA OPEN ACCESS PLUS', 'MI', N'LabState', 1038, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CIGNA - OPEN ACCESS PLUS', 1),
    (250, N'CIGNA PAYER O2308', 'MI', N'LabState', 1038, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'CIGNA PAYER O2308', 1),
    (251, N'DO NOT USE USE ANTHEM GA BCBSGA', 'GA', N'NameEmbedded', 1013, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'DO NOT USE-USE ANTHEM GA - BCBSGA', 1),
    (252, N'FLORIDA BLUE BLUE CROSS BLUE SHIELD OF FLORIDA', 'FL', N'NameEmbedded', 1034, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'FLORIDA BLUE-BLUE CROSS & BLUE SHIELD OF FLORIDA', 1),
    (253, N'HEALTH FIRST COLORADO HLTCO', 'CO', N'NameEmbedded', 1082, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'HEALTH FIRST COLORADO - HLTCO', 1),
    (254, N'HEALTH FIRST HEALTH PLANS HEAL1', 'AL', N'LabState', 1082, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'HEALTH FIRST HEALTH PLANS - HEAL1', 1),
    (255, N'HEALTH FIRST HEALTH PLANS HEAL1', 'CO', N'LabState', 1082, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'HEALTH FIRST HEALTH PLANS - HEAL1', 1),
    (256, N'HEALTH PLANS INC CIGNA', 'MI', N'LabState', 1038, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'HEALTH PLANS INC - CIGNA (PPO)', 1),
    (257, N'HEALTHEZ AETNA', 'MI', N'LabState', 1001, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'HEALTHEZ - AETNA (PPO)', 1),
    (258, N'HEALTHY BLUE LOUISIANA MEDICAID HBLAMD', 'LA', N'NameEmbedded', 1070, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'HEALTHY BLUE LOUISIANA MEDICAID - HBLAMD', 1),
    (259, N'HEALTHY BLUE NORTH CAROLINA', 'NC', N'NameEmbedded', 1049, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'HEALTHY BLUE NORTH CAROLINA', 1),
    (260, N'HEALTHY BLUE NORTH CAROLINA HBNC', 'NC', N'NameEmbedded', 1049, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'HEALTHY BLUE NORTH CAROLINA - HBNC', 1),
    (261, N'HEALTHY BLUE NORTH CAROLINA HEAL2', 'NC', N'NameEmbedded', 1049, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'HEALTHY BLUE NORTH CAROLINA - HEAL2', 1),
    (262, N'HEALTHY BLUE OF NORTH CAROLINA HBNC', 'NC', N'NameEmbedded', 1049, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'HEALTHY BLUE OF NORTH CAROLINA - HBNC', 1),
    (263, N'HUMANA', 'IL', N'LabState', 1071, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'HUMANA', 1),
    (264, N'HUMANA', 'MI', N'LabState', 1071, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'HUMANA (PPO)', 2),
    (265, N'HUMANA', 'MS', N'LabState', 1071, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'Humana', 1),
    (266, N'HUMANA', 'TX', N'LabState', 1071, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'HUMANA', 1),
    (267, N'HUMANA CHOICE', 'MI', N'LabState', 1071, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'HUMANA CHOICE', 2),
    (268, N'HUMANA CLAIMS OFFICE', 'MI', N'LabState', 1071, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'HUMANA CLAIMS OFFICE', 1),
    (269, N'HUMANA HEALTH CARE PLAN', 'MI', N'LabState', 1071, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'HUMANA HEALTH CARE PLAN', 1),
    (270, N'HUMANA HUMA', 'AL', N'LabState', 1071, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'HUMANA - HUMA', 1),
    (271, N'HUMANA HUMA', 'CO', N'LabState', 1071, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'HUMANA - HUMA', 1),
    (272, N'HUMANA HUMA', 'TX', N'LabState', 1071, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'HUMANA - HUMA', 1),
    (273, N'HUMANA HUMA', NULL, NULL, 1071, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'HUMANA - HUMA', 4),
    (274, N'HUMANA INC', 'MI', N'LabState', 1071, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'HUMANA INC.', 1),
    (275, N'HUMANA MEDICAL PLAN OF MICHIGAN INC', 'MI', N'NameEmbedded', 1071, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'HUMANA MEDICAL PLAN OF MICHIGAN, INC.', 1),
    (276, N'LOUISIANA HEALTH CONNECTIONS LHC', 'LA', N'NameEmbedded', 1214, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'LOUISIANA HEALTH CONNECTIONS - LHC', 1),
    (277, N'MAGNOLIA CAN HEALTH PLAN', 'MS', N'LabState', 1087, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MAGNOLIA CAN HEALTH PLAN', 1),
    (278, N'MAGNOLIA HEALTH PLAN', 'MS', N'LabState', 1087, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MAGNOLIA HEALTH PLAN', 1),
    (279, N'MAGNOLIA HEALTH PLAN MISSISSIPPI MHPMS', 'MS', N'NameEmbedded', 1087, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MAGNOLIA HEALTH PLAN-MISSISSIPPI - MHPMS', 2),
    (280, N'MCLAREN MEDICAID / HLTHY MI PLAN', 'MI', N'NameEmbedded', 1099, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MCLAREN MEDICAID / HLTHY MI PLAN', 1),
    (281, N'MEDI CAL CAL03', NULL, NULL, 1215, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MEDI-CAL - CAL03', 1),
    (282, N'MEDICAID', 'IL', N'LabState', 1096, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MEDICAID', 1),
    (283, N'MEDICAID AL MDAL', 'AL', N'NameEmbedded', 1119, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MEDICAID-AL - MDAL', 2),
    (284, N'MEDICAID AR MDAR', 'AR', N'NameEmbedded', 1089, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MEDICAID-AR - MDAR', 1),
    (285, N'MEDICAID AZ MDAZ', 'AZ', N'NameEmbedded', 1090, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MEDICAID-AZ - MDAZ', 2),
    (286, N'MEDICAID CA MEDI CAL CAL03', 'CA', N'NameEmbedded', 1215, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MEDICAID-CA (MEDI-CAL) - CAL03', 1),
    (287, N'MEDICAID CO COMD', 'CO', N'NameEmbedded', 1082, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MEDICAID-CO - COMD', 2),
    (288, N'MEDICAID CO HEALTH FIRST COMD', 'CO', N'NameEmbedded', 1082, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MEDICAID-CO (HEALTH FIRST) - COMD', 1),
    (289, N'MEDICAID GA GAMCD', 'GA', N'NameEmbedded', 1094, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MEDICAID - GA - GAMCD', 3),
    (290, N'MEDICAID ID MEDID', 'ID', N'NameEmbedded', 1095, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MEDICAID-ID - MEDID', 1),
    (291, N'MEDICAID LA LAMD', 'LA', N'NameEmbedded', 1098, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MEDICAID-LA - LAMD', 1),
    (292, N'MEDICAID MI', 'MI', N'NameEmbedded', 1099, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MEDICAID - MI', 1),
    (293, N'MEDICAID MO MOMCD', 'MO', N'NameEmbedded', 1120, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MEDICAID-MO - MOMCD', 3),
    (294, N'MEDICAID MS MSMCD', 'MS', N'NameEmbedded', 1100, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MEDICAID-MS - MSMCD', 3),
    (295, N'MEDICAID NEW MEXICO', 'NM', N'NameEmbedded', 1101, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MEDICAID (NEW MEXICO)', 1),
    (296, N'MEDICAID NM', 'NM', N'NameEmbedded', 1101, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MEDICAID NM', 1),
    (297, N'MEDICAID NV MDNV', 'NV', N'NameEmbedded', 1102, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MEDICAID-NV - MDNV', 1),
    (298, N'MEDICAID TX', 'TX', N'NameEmbedded', 1104, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MEDICAID TX', 1),
    (299, N'MEDICAID UT MDUT', 'UT', N'NameEmbedded', 1105, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MEDICAID-UT - MDUT', 1),
    (300, N'MEDICARE', 'IL', N'LabState', 1195, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MEDICARE', 1),
    (301, N'MEDICARE', NULL, NULL, 1186, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'Medicare', 1),
    (302, N'MEDICARE ALABAMA MCR', 'AL', N'NameEmbedded', 1204, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MEDICARE ALABAMA - MCR', 1),
    (303, N'MEDICARE COLORADO MCR', 'CO', N'NameEmbedded', 1086, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MEDICARE COLORADO - MCR', 1),
    (304, N'MEDICARE ILLIONS', 'IL', N'LabState', 1195, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MEDICARE ILLIONS', 1),
    (305, N'MEDICARE MD MCRMD', 'MD', N'NameEmbedded', 1185, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MEDICARE-MD - MCRMD', 1),
    (306, N'MEDICARE OFFICE USE', 'IL', N'LabState', 1195, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MEDICARE (OFFICE USE)', 1),
    (307, N'MEDICARE PART B', 'MI', N'LabState', 1117, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MEDICARE PART B', 1),
    (308, N'MEDICARE PART B OF MICHIG', 'MI', N'LabState', 1117, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MEDICARE PART B OF MICHIG', 1),
    (309, N'MEDICARE RAILROAD', 'IL', N'LabState', 1195, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MEDICARE RAILROAD', 1),
    (310, N'MEDICARE SC MCR', 'SC', N'NameEmbedded', 1207, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MEDICARE-SC - MCR', 1),
    (311, N'MEDICARE TEXAS MCR', 'TX', N'NameEmbedded', 1192, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MEDICARE TEXAS - MCR', 1),
    (312, N'MEDICARE TX', 'TX', N'NameEmbedded', 1191, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MEDICARE TX', 1),
    (313, N'MEDICIAD IL MEDIL', 'IL', N'NameEmbedded', 1096, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MEDICIAD-IL - MEDIL', 1),
    (314, N'MERCY CARE MCD', 'TX', N'LabState', 1090, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MERCY CARE (MCD)', 1),
    (315, N'MERCY CARE OF AZ MERC1', 'AZ', N'NameEmbedded', 1090, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MERCY CARE OF AZ - MERC1', 1),
    (316, N'MERCY CARE PLAN AHCCCS', 'TX', N'LabState', 1090, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MERCY CARE PLAN AHCCCS', 1),
    (317, N'MERCY CARE PLAN OF ARIZONA MERC1', 'AZ', N'NameEmbedded', 1090, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MERCY CARE PLAN OF ARIZONA - MERC1', 1),
    (318, N'MERCY CARE RBHA MCMIP', 'CO', N'LabState', 1090, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MERCY CARE RBHA - MCMIP', 1),
    (319, N'MERCY CARE RBHA MENTAL HEALTH MCMIP', NULL, NULL, 1090, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MERCY CARE RBHA (MENTAL HEALTH) - MCMIP', 1),
    (320, N'MERIDIAN', 'IL', N'LabState', 1139, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MERIDIAN', 1),
    (321, N'MERIDIAN HEALTH ILLINOIS', 'IL', N'NameEmbedded', 1139, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'Meridian Health Illinois', 1),
    (322, N'MERIDIAN HEALTH PLAN', 'IL', N'LabState', 1139, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MERIDIAN HEALTH PLAN', 1),
    (323, N'MERIDIAN HEALTH PLAN MICH', 'MI', N'LabState', 1133, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MERIDIAN HEALTH PLAN MICH', 1),
    (324, N'MERIDIAN HEALTH PLAN OF IL MHPIL', 'IL', N'NameEmbedded', 1139, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MERIDIAN HEALTH PLAN OF IL - MHPIL', 3),
    (325, N'MERIDIAN HEALTH PLAN OF ILLINOIS', 'IL', N'NameEmbedded', 1139, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'Meridian Health Plan Of Illinois', 1),
    (326, N'MERIDIAN HEALTH PLAN OF M', 'MI', N'LabState', 1133, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MERIDIAN HEALTH PLAN OF M', 1),
    (327, N'MERIDIAN HEALTH PLAN OF MI', 'MI', N'NameEmbedded', 1133, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MERIDIAN HEALTH PLAN OF MI', 1),
    (328, N'MERIDIAN HEALTH PLAN OF MICHIGAN AMBETTER FROM MERIDIAN', 'MI', N'NameEmbedded', 1133, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MERIDIAN HEALTH PLAN OF MICHIGAN - AMBETTER FROM MERIDIAN -', 1),
    (329, N'MERIDIAN HEALTH PLAN OF MICHIGAN AMBETTER FROM MERIDIAN DOS ON OR AFTER 1/1/2021', 'MI', N'NameEmbedded', 1133, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MERIDIAN HEALTH PLAN OF MICHIGAN - AMBETTER FROM MERIDIAN - DOS ON OR AFTER 1/1/2021 (HMO)', 1),
    (330, N'MERIDIAN HEALTH PLAN OF MICHIGAN AMBETTER FROM MERIDIAN E', 'MI', N'NameEmbedded', 1133, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MERIDIAN HEALTH PLAN OF MICHIGAN - AMBETTER FROM MERIDIAN (E', 1),
    (331, N'MERIDIAN HEALTH PLAN OF MICHIGAN COMPLETE', 'MI', N'NameEmbedded', 1133, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MERIDIAN HEALTH PLAN OF MICHIGAN COMPLETE', 1),
    (332, N'MERIDIAN MERIDIAN HEALTH PLAN', 'MI', N'LabState', 1133, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MERIDIAN - MERIDIAN HEALTH PLAN', 1),
    (333, N'MERIDIAN MMAI', 'IL', N'LabState', 1139, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MERIDIAN MMAI', 1),
    (334, N'MERITAIN HEALTH', 'IL', N'LabState', 1134, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'Meritain Health', 1),
    (335, N'MERITAIN HEALTH', 'TX', N'LabState', 1134, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MERITAIN HEALTH', 1),
    (336, N'MERITAIN HEALTH MINNEAPOLIS MER01', NULL, NULL, 1134, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MERITAIN HEALTH MINNEAPOLIS - MER01', 1),
    (337, N'MERITAIN HEALTH PLAN MER01', 'CO', N'LabState', 1134, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MERITAIN HEALTH PLAN - MER01', 1),
    (338, N'MI MEDICAID', 'MI', N'NameEmbedded', 1099, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MI MEDICAID', 1),
    (339, N'MI UHC HEALTHY MICHIGAN', 'MI', N'NameEmbedded', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'Mi Uhc Healthy Michigan', 1),
    (340, N'MOLINA', 'MI', N'LabState', 1140, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MOLINA', 1),
    (341, N'MOLINA COMMERCIAL', 'MI', N'LabState', 1140, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'Molina Commercial', 1),
    (342, N'MOLINA HEALTH CARE MICHIGAN', 'MI', N'NameEmbedded', 1140, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MOLINA HEALTH CARE MICHIGAN', 1),
    (343, N'MOLINA HEALTH CARE OF MI', 'MI', N'NameEmbedded', 1140, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MOLINA HEALTH CARE OF MI', 1),
    (344, N'MOLINA HEALTH PLAN', 'MI', N'LabState', 1140, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MOLINA HEALTH PLAN', 1),
    (345, N'MOLINA HEALTHCARE', 'IL', N'LabState', 1137, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MOLINA HEALTHCARE', 1),
    (346, N'MOLINA HEALTHCARE MOLINA HEALTHCARE OF MICHIGAN', 'MI', N'NameEmbedded', 1140, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MOLINA HEALTHCARE - MOLINA HEALTHCARE OF MICHIGAN', 1),
    (347, N'MOLINA HEALTHCARE OF IDAHO MLNID', 'ID', N'NameEmbedded', 1138, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MOLINA HEALTHCARE OF IDAHO - MLNID', 1),
    (348, N'MOLINA HEALTHCARE OF IL', 'IL', N'NameEmbedded', 1139, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'Molina Healthcare of IL', 1),
    (349, N'MOLINA HEALTHCARE OF MI', 'MI', N'NameEmbedded', 1140, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MOLINA HEALTHCARE OF MI', 1),
    (350, N'MOLINA HEALTHCARE OF MS', 'MS', N'NameEmbedded', 1140, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MOLINA HEALTHCARE OF MS', 1),
    (351, N'MOLINA ID MOLID', 'ID', N'NameEmbedded', 1138, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MOLINA-ID - MOLID', 1),
    (352, N'MOLINA IL', 'IL', N'NameEmbedded', 1139, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MOLINA IL', 1),
    (353, N'MOLINA IL MOLIL', 'IL', N'NameEmbedded', 1139, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MOLINA - IL - MOLIL', 1),
    (354, N'MOLINA MI MOLMI', 'MI', N'NameEmbedded', 1140, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MOLINA - MI - MOLMI', 2),
    (355, N'MOLINA MOLINA HEALTH CARE OF MI', 'MI', N'NameEmbedded', 1140, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MOLINA - MOLINA HEALTH CARE OF MI', 1),
    (356, N'MOLINA MS MOLMS', 'MS', N'NameEmbedded', 1140, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'MOLINA-MS - MOLMS', 3),
    (357, N'NONE', NULL, NULL, 9999, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'* none *', 1),
    (358, N'OSCAR', 'TX', N'LabState', 1121, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'OSCAR', 1),
    (359, N'OSCAR HEALTH PLAN OSCA1', 'CO', N'LabState', 1121, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'OSCAR HEALTH PLAN - OSCA1', 1),
    (360, N'OSCAR HEALTH PLAN OSCA1', NULL, NULL, 1121, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'OSCAR HEALTH PLAN - OSCA1', 1),
    (361, N'OSCAR INSURANCE COMPANY', 'IL', N'LabState', 1121, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'OSCAR INSURANCE COMPANY', 1),
    (362, N'OSCAR OSCA1', 'AL', N'LabState', 1121, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'OSCAR - OSCA1', 1),
    (363, N'PEACH STATE HEALTH PLAN PEAC1', 'CO', N'LabState', 1213, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'PEACH STATE HEALTH PLAN - PEAC1', 1),
    (364, N'PEACH STATE HEALTH PLAN PEAC1', NULL, NULL, 1213, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'PEACH STATE HEALTH PLAN - PEAC1', 2),
    (365, N'PEACHSTATE HEALTH PEAC1', NULL, NULL, 1213, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'PEACHSTATE HEALTH - PEAC1', 1),
    (366, N'PENNSYLVANIA MEDICARE MCR', 'PA', N'NameEmbedded', 1190, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'PENNSYLVANIA MEDICARE - MCR', 1),
    (367, N'PRESBYTARIAN CENTENNIAL CARE', 'IL', N'LabState', 1151, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'PRESBYTARIAN CENTENNIAL CARE', 1),
    (368, N'PRESBYTARIAN COMMERCIAL', 'IL', N'LabState', 1151, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'PRESBYTARIAN COMMERCIAL', 1),
    (369, N'PRESBYTERIAN CENTENNIAL CARE', 'IL', N'LabState', 1151, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'PRESBYTERIAN CENTENNIAL CARE', 1),
    (370, N'PRIORITY HEALTH', 'MI', N'LabState', 1152, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'PRIORITY HEALTH (HMO)', 3),
    (371, N'PRIORITY HEALTH', 'TX', N'LabState', 1152, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'PRIORITY HEALTH', 1),
    (372, N'PRIORITY HEALTH CARE PHC', NULL, NULL, 1152, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'PRIORITY HEALTH CARE - PHC', 2),
    (373, N'PRIORITY HEALTH CIGNA', 'MI', N'LabState', 1152, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'PRIORITY HEALTH - CIGNA (POS)', 1),
    (374, N'PRIORITY HEALTH OF MI PHMI', 'MI', N'NameEmbedded', 1152, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'PRIORITY HEALTH OF MI - PHMI', 1),
    (375, N'PRIORITY HEALTH OF MICHIGAN', 'MI', N'NameEmbedded', 1152, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'PRIORITY HEALTH OF MICHIGAN', 1),
    (376, N'PRIORITY HEALTH OF MICHIGAN PHMI', 'MI', N'NameEmbedded', 1152, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'PRIORITY HEALTH OF MICHIGAN - PHMI', 1),
    (377, N'PRIORITY HEALTH PLAN', 'MI', N'LabState', 1152, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'PRIORITY HEALTH PLAN', 1),
    (378, N'PRIORITY HEALTH PRIORITY HEALTH', 'MI', N'LabState', 1152, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'PRIORITY HEALTH - PRIORITY HEALTH', 1),
    (379, N'REGENCE BLUE CROSS BLUE SHIELD OF U UTREBS', NULL, NULL, 1155, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'REGENCE BLUE CROSS BLUE SHIELD OF U - UTREBS', 1),
    (380, N'REGENCE BLUE CROSS OF OREGON REGOR', 'OR', N'NameEmbedded', 1154, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'REGENCE BLUE CROSS OF OREGON - REGOR', 1),
    (381, N'REGENCE BLUE CROSS OF WASHINGTON REGWA', 'WA', N'NameEmbedded', 1157, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'REGENCE BLUE CROSS OF WASHINGTON - REGWA', 1),
    (382, N'REGENCE BLUE SHIELD IDAHO REGID', 'ID', N'NameEmbedded', 1156, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'REGENCE BLUE SHIELD IDAHO - REGID', 1),
    (383, N'SIMPLY HEALTHCARE SIMP1', NULL, NULL, 1076, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'SIMPLY HEALTHCARE - SIMP1', 1),
    (384, N'SUNSHINE HEALTH', 'MS', N'LabState', 1161, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'SUNSHINE HEALTH', 1),
    (385, N'SUNSHINE HEALTH SUNH', NULL, NULL, 1161, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'SUNSHINE HEALTH - SUNH', 1),
    (386, N'SUNSHINE STATE HEALTH PLAN', 'FL', N'LabState', 1161, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'SUNSHINE STATE HEALTH PLAN', 1),
    (387, N'SUNSHINE STATE HEALTH PLAN AMBETTE SUNH', NULL, NULL, 1161, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'SUNSHINE STATE HEALTH PLAN (AMBETTE - SUNH', 1),
    (388, N'SUNSHINE STATE HEALTH PLAN SUN01', 'FL', N'LabState', 1161, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'SUNSHINE STATE HEALTH PLAN - SUN01', 1),
    (389, N'SUNSHINE STATE HEALTH PLAN SUNH', NULL, NULL, 1161, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'SUNSHINE STATE HEALTH PLAN - SUNH', 1),
    (390, N'SUNSHINE STATE HEALTH PLAN SUP01', NULL, NULL, 1161, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'SUNSHINE STATE HEALTH PLAN - SUP01', 1),
    (391, N'SUPERIOR HEALTH PLAN', 'TX', N'LabState', 1162, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'SUPERIOR HEALTH PLAN', 1),
    (392, N'TENNESSE BLUECARE TNBCR', 'CO', N'LabState', 1058, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'TENNESSE BLUECARE - TNBCR', 1),
    (393, N'TENNESSEE BLUECARE TNBCR', 'TN', N'NameEmbedded', 1058, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'TENNESSEE BLUECARE - TNBCR', 1),
    (394, N'TEXAS CHILDRENS HEALTH PLAN', 'TX', N'NameEmbedded', 1104, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'TEXAS CHILDRENS HEALTH PLAN', 1),
    (395, N'TEXAS MEDICAID', 'TX', N'NameEmbedded', 1104, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'TEXAS MEDICAID', 1),
    (396, N'UHC', 'TX', N'LabState', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UHC', 1),
    (397, N'UHC GLOBAL', 'FL', N'LabState', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UHC GLOBAL', 1),
    (398, N'UHC GLOBAL UHC 2', 'FL', N'LabState', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UHC GLOBAL - UHC 2', 1),
    (399, N'UHC OF TEXAS', 'TX', N'NameEmbedded', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UHC of Texas', 1),
    (400, N'UHC OFFICE USE', 'IL', N'LabState', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UHC (OFFICE USE)', 1);
GO

INSERT INTO dbo.PayerAlias (AliasId, CanonicalName, ResolvedStateCode, StateSignalSource, GlobalPayerId, ConfirmedBy, ConfirmedDate, SourceAction, ExampleRawName, SourceRowCount) VALUES
    (401, N'UHC SHARED SERIVES', 'IL', N'LabState', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UHC Shared Serives', 1),
    (402, N'UHC SUREST', 'TX', N'LabState', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UHC SUREST', 1),
    (403, N'UHC UHC', NULL, NULL, 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UHC - UHC', 1),
    (404, N'UHC UNI20', 'FL', N'LabState', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UHC - UNI20', 1),
    (405, N'UNITED HEALTH CARE', 'MI', N'LabState', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UNITED HEALTH CARE', 1),
    (406, N'UNITED HEALTH CARE', 'MS', N'LabState', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'United Health Care', 1),
    (407, N'UNITED HEALTH CARE CHOICE', 'MI', N'LabState', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UNITED HEALTH CARE CHOICE', 1),
    (408, N'UNITED HEALTH CARE CORE', 'IL', N'LabState', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UNITED HEALTH CARE CORE', 1),
    (409, N'UNITED HEALTH CARE UHC', 'TX', N'LabState', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UNITED HEALTH CARE - UHC', 1),
    (410, N'UNITED HEALTH CARE UHC MCR', 'IL', N'LabState', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UNITED HEALTH CARE ( UHC) MCR PPO', 1),
    (411, N'UNITED HEALTH CARE UHCH0', 'IL', N'LabState', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UNITED HEALTH CARE UHCH0', 1),
    (412, N'UNITED HEALTH PLAN ENCOUNTERS', 'MI', N'LabState', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UNITED HEALTH PLAN ENCOUNTERS', 1),
    (413, N'UNITED HEALTH SHARED SERVICES', 'MS', N'LabState', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UNITED HEALTH SHARED SERVICES', 1),
    (414, N'UNITED HEALTHCARE', 'IL', N'LabState', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UNITED HEALTHCARE', 1),
    (415, N'UNITED HEALTHCARE', 'MI', N'LabState', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UNITED HEALTHCARE (PPO)', 2),
    (416, N'UNITED HEALTHCARE CHOICE PLUS', 'MI', N'LabState', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UNITED HEALTHCARE CHOICE PLUS', 1),
    (417, N'UNITED HEALTHCARE CHOICE PLUS', 'MS', N'LabState', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'United Healthcare Choice Plus', 1),
    (418, N'UNITED HEALTHCARE EXCHANGE PLAN MI', 'MI', N'NameEmbedded', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UNITED HEALTHCARE - EXCHANGE PLAN - MI (HMO)', 1),
    (419, N'UNITED HEALTHCARE EXCHANGE PLAN OH', 'OH', N'NameEmbedded', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UNITED HEALTHCARE - EXCHANGE PLAN - OH (HMO)', 1),
    (420, N'UNITED HEALTHCARE GEHA', 'MS', N'LabState', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UNITED HEALTHCARE(GEHA)', 1),
    (421, N'UNITED HEALTHCARE OF KENTUCKY', 'KY', N'NameEmbedded', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UNITED HEALTHCARE OF KENTUCKY', 1),
    (422, N'UNITED HEALTHCARE OF MICHIGAN', 'MI', N'NameEmbedded', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UNITED HEALTHCARE OF MICHIGAN', 1),
    (423, N'UNITED HEALTHCARE OXFORD HEALTH', 'MS', N'LabState', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'United Healthcare Oxford Health', 1),
    (424, N'UNITED HEALTHCARE SHARED SERVICES', 'IL', N'LabState', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'United healthcare shared services', 1),
    (425, N'UNITED HEALTHCARE UHC', 'AL', N'LabState', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UNITED HEALTHCARE - UHC', 1),
    (426, N'UNITED HEALTHCARE UHC', 'CO', N'LabState', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UNITED HEALTHCARE - UHC', 1),
    (427, N'UNITED HEALTHCARE UHC', NULL, NULL, 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UNITED HEALTHCARE - UHC', 3),
    (428, N'UNITED HEALTHCARE UHC CHOICE PLUS', 'MI', N'LabState', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UNITED HEALTHCARE - UHC CHOICE PLUS', 1),
    (429, N'UNITEDHEALTH GROUP', 'MI', N'LabState', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UNITEDHEALTH GROUP', 1),
    (430, N'UNITEDHEALTHCARE', 'MI', N'LabState', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UNITEDHEALTHCARE', 1),
    (431, N'UNITEDHEALTHCARE CHOICE PLUS', 'MI', N'LabState', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UNITEDHEALTHCARE CHOICE PLUS', 1),
    (432, N'UNITEDHEALTHCARE COMMUNITY PLAN MO UHCPMO', 'MO', N'NameEmbedded', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UNITEDHEALTHCARE COMMUNITY PLAN MO - UHCPMO', 1),
    (433, N'UNITEDHEALTHCARE GLHP', 'MI', N'LabState', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UNITEDHEALTHCARE (GLHP)', 1),
    (434, N'UNITEDHEALTHCARE INSURANCE COMPANY', 'MI', N'LabState', 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UNITEDHEALTHCARE INSURANCE COMPANY', 1),
    (435, N'UNITEDHEALTHCARE SHARED SERVICES UNIT2', NULL, NULL, 1118, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'UNITEDHEALTHCARE SHARED SERVICES - UNIT2', 1),
    (436, N'VETTRAIN AFFAIRS', 'TX', N'LabState', 1164, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'VETTRAIN AFFAIRS', 1),
    (437, N'WA BLUE SHIELD REGENCE', 'WA', N'NameEmbedded', 1157, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'WA BLUE SHIELD - REGENCE', 1),
    (438, N'WA/AK BLUE CROSS PREMERA', 'WA', N'NameEmbedded', 1157, N'System (Seeded from Lab Insurance Master v1.8.4)', '2026-07-08', N'Seeded', N'WA/AK BLUE CROSS - PREMERA', 1);
GO

/* =====================================================================
   Verification
   ===================================================================== */
SELECT 'USStateCode'         AS TableName, COUNT(*) AS Rows FROM dbo.USStateCode
UNION ALL SELECT 'PayerFamilyRule',      COUNT(*) FROM dbo.PayerFamilyRule
UNION ALL SELECT 'StateBrandMapping',    COUNT(*) FROM dbo.StateBrandMapping
UNION ALL SELECT 'ProgramTypeRule',      COUNT(*) FROM dbo.ProgramTypeRule
UNION ALL SELECT 'ProductLineRule',      COUNT(*) FROM dbo.ProductLineRule
UNION ALL SELECT 'PlanNetworkTypeCode',  COUNT(*) FROM dbo.PlanNetworkTypeCode
UNION ALL SELECT 'PayerAlias',           COUNT(*) FROM dbo.PayerAlias;
GO
