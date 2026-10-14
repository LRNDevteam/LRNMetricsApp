-- ============================================================
-- Table: dbo.PanelGroup
-- Lookup mapping of Panel Name -> Panel Group
-- ============================================================

IF OBJECT_ID('dbo.PanelGroup', 'U') IS NOT NULL
    DROP TABLE dbo.PanelGroup;
GO

CREATE TABLE dbo.PanelGroup
(
    PanelGroupID INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    PanelName    NVARCHAR(200) NOT NULL,
    PanelGroup   NVARCHAR(100) NOT NULL
);
GO

INSERT INTO dbo.PanelGroup (PanelName, PanelGroup) VALUES
('UTI Panel',            'Molecular'),
('RPP Panel',             'Molecular'),
('GI Panel',              'Molecular'),
('Wound Panel',           'Molecular'),
('WH Panel/Male STI',     'Molecular'),
('Client',                'Client'),
('Toxicology',            'Toxicology'),
('Blood',                 'Blood'),
('CGX',                   'Genetics'),
('Cardio',                'Genetics'),
('PGx',                   'Genetics'),
('Nail Panel',            'Molecular'),
('Urinalysis',            'Molecular'),
('WH Panel',              'Molecular'),
('Nail Fungal Panel',     'Molecular'),
('Unable to locate',      'Molecular'),
('UTI + Wound',           'Molecular'),
('Unable to locate',      'Genetics'),
('Rejection',             'Genetics'),
('HIV',                   'Molecular'),
('UTI + WH/Male STI',     'Molecular'),
('Rejection',             'Toxicology'),
('STI Panel',             'Molecular'),
('GI + UTI',              'Molecular'),
('Male STI',              'Molecular'),
('Rejection',             'Molecular');
GO
