-- Projet SQL avance B2 : gestion d'un tournoi e-sport
-- PostgreSQL. Script a executer sur une base vide avec un compte administrateur.
-- Les donnees de demonstration sont generees automatiquement.

BEGIN;

-- 1. TABLES
CREATE TABLE teams (
    team_id BIGSERIAL PRIMARY KEY,
    team_name TEXT NOT NULL UNIQUE,
    country CHAR(2) NOT NULL DEFAULT 'FR'
);

CREATE TABLE players (
    player_id BIGSERIAL PRIMARY KEY,
    team_id BIGINT NOT NULL REFERENCES teams(team_id),
    nickname TEXT NOT NULL UNIQUE,
    joined_at DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE tournaments (
    tournament_id BIGSERIAL PRIMARY KEY,
    tournament_name TEXT NOT NULL UNIQUE,
    starts_on DATE NOT NULL,
    ends_on DATE NOT NULL,
    CONSTRAINT tournament_dates CHECK (ends_on >= starts_on)
);

CREATE TABLE matches (
    match_id BIGSERIAL PRIMARY KEY,
    tournament_id BIGINT NOT NULL REFERENCES tournaments(tournament_id),
    home_team_id BIGINT NOT NULL REFERENCES teams(team_id),
    away_team_id BIGINT NOT NULL REFERENCES teams(team_id),
    played_at TIMESTAMPTZ NOT NULL,
    home_score INTEGER,
    away_score INTEGER,
    result_validated BOOLEAN NOT NULL DEFAULT FALSE,
    CONSTRAINT different_teams CHECK (home_team_id <> away_team_id),
    CONSTRAINT nonnegative_scores CHECK (
        (home_score IS NULL AND away_score IS NULL)
        OR (home_score >= 0 AND away_score >= 0)
    )
);

-- 2. DONNEES DE DEMONSTRATION
INSERT INTO teams(team_name, country) VALUES
 ('Pixel Wolves','FR'), ('Nova Squad','FR'), ('Blue Comets','BE'),
 ('Red Phoenix','CH'), ('Cyber Lions','FR'), ('Storm Unit','BE'),
 ('Night Owls','FR'), ('Quantum Five','CH'), ('Delta Force','FR'),
 ('Golden Byte','BE'), ('Iron Pulse','FR'), ('Next Level','CH'),
 ('Shadow Core','FR'), ('Team Orbit','BE'), ('Rapid Foxes','FR'),
 ('Zero Lag','CH'), ('Neon Tigers','FR'), ('Alpha Stack','BE'),
 ('Vortex Club','FR'), ('Final Boss','CH');

INSERT INTO tournaments(tournament_name, starts_on, ends_on)
VALUES ('Campus E-sport Cup 2026', DATE '2026-10-01', DATE '2026-12-31');

INSERT INTO players(team_id, nickname)
SELECT t.team_id, t.team_name || '_player_' || n
FROM teams t CROSS JOIN generate_series(1,5) AS n;

-- 10 000 lignes dans la plus grosse table, comme demande dans le sujet.
INSERT INTO matches(tournament_id, home_team_id, away_team_id, played_at,
                    home_score, away_score, result_validated)
SELECT 1,
       1 + ((i - 1) % 20),
       1 + ((i + 8) % 20),
       TIMESTAMPTZ '2026-01-01 12:00:00+00' + ((i % 300) * INTERVAL '1 day'),
       (i % 5), ((i + 2) % 5), FALSE
FROM generate_series(1,10000) AS s(i);

-- 3. FONCTION : valider le resultat d'un match
CREATE OR REPLACE FUNCTION validate_match_result(p_match_id BIGINT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_home INTEGER;
    v_away INTEGER;
BEGIN
    SELECT home_score, away_score
      INTO v_home, v_away
      FROM matches
     WHERE match_id = p_match_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Match % introuvable', p_match_id;
    END IF;
    IF v_home IS NULL OR v_away IS NULL THEN
        RAISE EXCEPTION 'Impossible de valider un score incomplet pour le match %', p_match_id;
    END IF;

    UPDATE matches SET result_validated = TRUE WHERE match_id = p_match_id;
    RETURN format('Resultat du match %s valide : %s - %s', p_match_id, v_home, v_away);
END;
$$;

-- 4. TRIGGER : un resultat valide ne peut plus etre modifie
CREATE OR REPLACE FUNCTION protect_validated_result()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.result_validated AND
       (NEW.home_score IS DISTINCT FROM OLD.home_score
        OR NEW.away_score IS DISTINCT FROM OLD.away_score
        OR NEW.home_team_id IS DISTINCT FROM OLD.home_team_id
        OR NEW.away_team_id IS DISTINCT FROM OLD.away_team_id) THEN
        RAISE EXCEPTION 'Refus : le resultat du match % est deja valide', OLD.match_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_protect_validated_result
BEFORE UPDATE ON matches
FOR EACH ROW EXECUTE FUNCTION protect_validated_result();

-- 5. VUES : une vue par role-metier
CREATE OR REPLACE VIEW v_operator_matches AS
SELECT m.match_id, t.tournament_name,
       th.team_name AS home_team, ta.team_name AS away_team,
       m.played_at, m.home_score, m.away_score, m.result_validated
FROM matches m
JOIN tournaments t ON t.tournament_id = m.tournament_id
JOIN teams th ON th.team_id = m.home_team_id
JOIN teams ta ON ta.team_id = m.away_team_id;

CREATE OR REPLACE VIEW v_auditor_results AS
SELECT m.match_id, t.tournament_name,
       th.team_name AS home_team, ta.team_name AS away_team,
       m.played_at, m.home_score, m.away_score, m.result_validated
FROM matches m
JOIN tournaments t ON t.tournament_id = m.tournament_id
JOIN teams th ON th.team_id = m.home_team_id
JOIN teams ta ON ta.team_id = m.away_team_id
WHERE m.result_validated = TRUE;

-- 6. ROLES ET PRIVILEGES
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'tournament_operator') THEN
        CREATE ROLE tournament_operator NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'tournament_auditor') THEN
        CREATE ROLE tournament_auditor NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'operator_user') THEN
        CREATE ROLE operator_user LOGIN PASSWORD 'OperatorDemo_2026';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'auditor_user') THEN
        CREATE ROLE auditor_user LOGIN PASSWORD 'AuditorDemo_2026';
    END IF;
END $$;

GRANT tournament_operator TO operator_user;
GRANT tournament_auditor TO auditor_user;
REVOKE ALL ON teams, players, tournaments, matches FROM PUBLIC;
REVOKE ALL ON teams, players, tournaments, matches FROM tournament_operator, tournament_auditor;
REVOKE ALL ON v_operator_matches, v_auditor_results FROM PUBLIC;
GRANT SELECT ON v_operator_matches TO tournament_operator;
GRANT SELECT ON v_auditor_results TO tournament_auditor;
GRANT USAGE ON SCHEMA public TO tournament_operator, tournament_auditor;
GRANT EXECUTE ON FUNCTION validate_match_result(BIGINT) TO tournament_operator;

-- 7. INDEX : mesure avant / apres avec EXPLAIN ANALYZE
-- Avant indexation : garder la sortie EXPLAIN ANALYZE pour la comparaison.
EXPLAIN (ANALYZE, BUFFERS)
SELECT match_id, played_at, home_score, away_score
FROM matches
WHERE played_at >= TIMESTAMPTZ '2026-06-01 00:00:00+00'
ORDER BY played_at;

CREATE INDEX idx_matches_played_at ON matches(played_at);
CREATE INDEX idx_matches_tournament_date ON matches(tournament_id, played_at);
ANALYZE matches;

-- Apres indexation : comparer Execution Time et le plan avec celui du dessus.
EXPLAIN (ANALYZE, BUFFERS)
SELECT match_id, played_at, home_score, away_score
FROM matches
WHERE played_at >= TIMESTAMPTZ '2026-06-01 00:00:00+00'
ORDER BY played_at;

COMMIT;

-- Tests de demonstration a lancer ensuite, individuellement :
-- SELECT COUNT(*) FROM matches; -- attendu : 10000
-- SELECT validate_match_result(1);
-- UPDATE matches SET home_score = 99 WHERE match_id = 1; -- attendu : refus du trigger
-- SET ROLE operator_user; SELECT * FROM v_operator_matches LIMIT 5;
-- SELECT * FROM matches; -- attendu : permission denied
-- RESET ROLE;
-- SET ROLE auditor_user; SELECT * FROM v_auditor_results LIMIT 5;
-- SELECT * FROM v_operator_matches; -- attendu : permission denied
-- RESET ROLE;
