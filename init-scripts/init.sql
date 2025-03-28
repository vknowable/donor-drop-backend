CREATE TABLE IF NOT EXISTS donations (
    id SERIAL PRIMARY KEY,
    transaction_hash VARCHAR(66) UNIQUE NOT NULL,
    from_address VARCHAR(42) NOT NULL,
    amount_eth DECIMAL(20,18) NOT NULL,
    namada_key VARCHAR(66) NOT NULL,
    input_message VARCHAR,
    message VARCHAR(100) NULL,
    timestamp TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    block_number BIGINT NOT NULL,
    tx_index INTEGER NOT NULL
);

-- Add index for timestamp-based queries
CREATE INDEX idx_donations_timestamp ON donations(timestamp);

CREATE INDEX idx_donations_address_timestamp ON donations(from_address, timestamp, amount_eth);

CREATE TABLE IF NOT EXISTS donations_finalized (
    id SERIAL PRIMARY KEY,
    transaction_hash VARCHAR(66) UNIQUE NOT NULL,
    from_address VARCHAR(42) NOT NULL,
    amount_eth DECIMAL(20,18) NOT NULL,
    namada_key VARCHAR(66) NOT NULL,
    input_message VARCHAR,
    message VARCHAR(100) NULL,
    timestamp TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    block_number BIGINT NOT NULL,
    tx_index INTEGER NOT NULL
);

-- Add index for timestamp-based queries
CREATE INDEX idx_donations_finalized_timestamp ON donations_finalized(timestamp);

CREATE INDEX idx_donations_finalized_address_timestamp ON donations_finalized(from_address, timestamp, amount_eth);

CREATE TABLE IF NOT EXISTS etherscan_transactions_all (
    id SERIAL PRIMARY KEY,
    transaction_hash VARCHAR(66) UNIQUE NOT NULL,
    from_address VARCHAR(42) NOT NULL,
    amount_eth DECIMAL(20,18) NOT NULL,
    namada_key VARCHAR(66) NOT NULL,
    input_message VARCHAR,
    message VARCHAR(100) NULL,
    timestamp TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    block_number BIGINT NOT NULL,
    tx_index INTEGER NOT NULL
);

-- Add index for timestamp-based queries
CREATE INDEX idx_etherscan_transactions_all_timestamp ON etherscan_transactions_all(timestamp);

CREATE INDEX idx_etherscan_transactions_all_address_timestamp ON etherscan_transactions_all(from_address, timestamp, amount_eth);

CREATE TABLE IF NOT EXISTS scraped_blocks (
    id SERIAL PRIMARY KEY,
    block_number BIGINT UNIQUE NOT NULL,
    scraped_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    transactions_found INTEGER DEFAULT 0
);

-- Create an index for faster block number lookups
CREATE INDEX idx_block_number ON scraped_blocks(block_number);

CREATE TABLE IF NOT EXISTS scraped_blocks_finalized (
    id SERIAL PRIMARY KEY,
    block_number BIGINT UNIQUE NOT NULL,
    scraped_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    transactions_found INTEGER DEFAULT 0
);

-- Create an index for faster block number lookups
CREATE INDEX idx_block_number_finalized ON scraped_blocks_finalized(block_number);

-- params table (TODO: useful for the next iteration, see issue #15)
-- CREATE TABLE IF NOT EXISTS params
-- (
-- global_eth_cap DECIMAL DEFAULT 30,
-- individual_eth_minimum DECIMAL DEFAULT 0.03,
-- individual_eth_cap DECIMAL DEFAULT 0.3,
-- reward_nam INTEGER DEFAULT 1000000,
-- start_date TIMESTAMPTZ NOT NULL,
-- end_date TIMESTAMPTZ NOT NULL
-- );

CREATE TABLE IF NOT EXISTS temporary_messages (
    from_address VARCHAR(42) PRIMARY KEY,
    message VARCHAR(100) NOT NULL,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS unaccounted_addresses (
    from_address VARCHAR(42) PRIMARY KEY,
    namada_key VARCHAR(66) NOT NULL,
    sig_hash VARCHAR(255) NOT NULL,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- Create the function to delete messages older than 10 minutes
CREATE OR REPLACE FUNCTION delete_old_messages()
RETURNS TRIGGER AS $$
BEGIN
    DELETE FROM temporary_messages
    WHERE created_at < NOW() - INTERVAL '10 minutes';
    RETURN NULL; -- No row needs to be returned
END;
$$ LANGUAGE plpgsql;

-- Create the trigger to call the function after insert or update
CREATE OR REPLACE TRIGGER expire_messages
AFTER INSERT OR UPDATE ON temporary_messages
FOR EACH ROW
EXECUTE FUNCTION delete_old_messages();

-- Views
DROP VIEW IF EXISTS combined_donations;
DROP VIEW IF EXISTS the_full_table;
DROP VIEW IF EXISTS the_finalized_transactions_full_table;
DROP VIEW IF EXISTS address_totals;
DROP VIEW IF EXISTS address_totals_finalized;
DROP VIEW IF EXISTS eligible_addresses;
DROP VIEW IF EXISTS eligible_addresses_finalized;
DROP VIEW IF EXISTS donation_stats;
DROP VIEW IF EXISTS donation_stats_finalized;
DROP VIEW IF EXISTS filtered_etherscan_not_in_db;
DROP VIEW IF EXISTS private_result_eligible_addresses_finalized_in_db;
DROP VIEW IF EXISTS private_result_above_cap_addresses_in_db;
DROP VIEW IF EXISTS private_result_addresses_not_in_db;

CREATE VIEW combined_donations AS
WITH temp AS (
    SELECT COALESCE(MAX(block_number), 0) as last_finalized_block
    FROM scraped_blocks_finalized
)
SELECT *
FROM donations_finalized 
WHERE block_number <= (SELECT last_finalized_block FROM temp)
UNION
SELECT *
FROM donations 
WHERE block_number > (SELECT last_finalized_block FROM temp);

CREATE VIEW the_full_table AS

-- query name totally new

WITH running_totals AS (
    -- Calculate running totals per address in transaction order
    SELECT 
        id,
        from_address,
        amount_eth,
        block_number,
        tx_index,
        SUM(amount_eth) OVER (
            PARTITION BY from_address
            ORDER BY block_number, tx_index
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) as address_running_total,

COALESCE(SUM(amount_eth) OVER (
            PARTITION BY from_address
            ORDER BY block_number, tx_index
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ), 0) as preceding_running_total

    FROM combined_donations
),
eligible_amounts AS (
--WITH the_big_temporary_table AS (
   --we gon do some smart stuff here
    SELECT 
        id,
        from_address,
        block_number,
        tx_index,
        amount_eth,
        address_running_total,
        preceding_running_total,
--these are eligible amount contributions for this particular transaction (not cumulative, unless previous donations have been too low..)
CASE
--not enough donations yet
WHEN address_running_total < 0.03 THEN 0
--already met the cap before this donation
WHEN preceding_running_total > 0.3 THEN 0
--previous donations under individual cap (if we are here in the struct, we have gone over cap already) contribution here will be either full address running total, or 0.3 if we go over the cap (ie running total > 0.3)
WHEN preceding_running_total < 0.03 THEN
LEAST(address_running_total, 0.3)
--if this transaction brought us over individual cap (and preceding cases excluded)
WHEN address_running_total > 0.3 THEN
(0.3 - preceding_running_total)

--all other cases
ELSE amount_eth
END
AS eligible_amount
    FROM running_totals
ORDER BY 1 )

SELECT 
        id,
        from_address,
        block_number,
        tx_index,
        amount_eth,
        address_running_total,
        preceding_running_total, eligible_amount,

SUM(eligible_amount) OVER (
            ORDER BY block_number, tx_index
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) as global_total

FROM eligible_amounts
ORDER BY 1;

CREATE VIEW the_finalized_transactions_full_table AS

-- query name totally new

WITH running_totals AS (
    -- Calculate running totals per address in transaction order
    SELECT 
        id,
        from_address,
        amount_eth,
        block_number,
        tx_index,
        namada_key,
        SUM(amount_eth) OVER (
            PARTITION BY from_address
            ORDER BY block_number, tx_index
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) as address_running_total,

COALESCE(SUM(amount_eth) OVER (
            PARTITION BY from_address
            ORDER BY block_number, tx_index
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ), 0) as preceding_running_total


    FROM donations_finalized
),
eligible_amounts AS (
--WITH the_big_temporary_table AS (
   --we gon do some smart stuff here
    SELECT 
        id,
        from_address,
        block_number,
        tx_index,
        namada_key,
        amount_eth,
        address_running_total,
        preceding_running_total,
--these are eligible amount contributions for this particular transaction (not cumulative, unless previous donations have been too low..)
CASE
--not enough donations yet
WHEN address_running_total < 0.03 THEN 0
--already met the cap before this donation
WHEN preceding_running_total > 0.3 THEN 0
--previous donations under individual cap (if we are here in the struct, we have gone over cap already) contribution here will be either full address running total, or 0.3 if we go over the cap (ie running total > 0.3)
WHEN preceding_running_total < 0.03 THEN
LEAST(address_running_total, 0.3)
--if this transaction brought us over individual cap (and preceding cases excluded)
WHEN address_running_total > 0.3 THEN
(0.3 - preceding_running_total)

--all other cases
ELSE amount_eth
END
AS eligible_amount
    FROM running_totals
ORDER BY 1 )

SELECT 
        id,
        from_address,
        block_number,
        tx_index,
        namada_key,
        amount_eth,
        address_running_total,
        preceding_running_total, eligible_amount,

SUM(eligible_amount) OVER (
            ORDER BY block_number, tx_index
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) as global_total

FROM eligible_amounts
ORDER BY 1;

CREATE VIEW address_totals AS

-- query name address totals

SELECT from_address, SUM(eligible_amount) AS eligible_amount, SUM(adjusted_amount_eth) AS total_amount_before_cutoff, SUM(amount_eth) AS total_amount_within_campaign_window

FROM (
SELECT id, from_address, amount_eth, 
block_number, tx_index,
--this is where we do the cool stuff
CASE 
WHEN global_total > 30.0 AND global_total - eligible_amount < 30.0
-- previous global total = global_total less eligible_amount
THEN 30.0 - (global_total - eligible_amount)
WHEN global_total > 30.0 THEN 0
ELSE eligible_amount 
END as eligible_amount,

CASE 
WHEN global_total > 30.0 AND global_total - eligible_amount < 30.0
-- previous global total = global_total less eligible_amount
THEN 30.0 - (global_total - eligible_amount)
WHEN global_total > 30.0 THEN 0
ELSE amount_eth
END as adjusted_amount_eth

 FROM the_full_table

) as query1

GROUP BY from_address
ORDER BY 1;


CREATE VIEW address_totals_finalized AS

-- query name address totals finalized only

SELECT from_address, 
MAX(namada_key) as tnam, SUM(eligible_amount) AS eligible_amount, 
SUM(eligible_amount_above_cap) AS eligible_above_cap,
SUM(adjusted_amount_eth) AS total_amount_before_cutoff, SUM(amount_eth) AS total_amount_within_campaign_window

FROM (
SELECT id, from_address, amount_eth, 
block_number, tx_index, namada_key,
--this is where we do the cool stuff
CASE 
WHEN global_total > 30.0 AND global_total - eligible_amount < 30.0
-- previous global total = global_total less eligible_amount
THEN 30.0 - (global_total - eligible_amount)
WHEN global_total > 30.0 THEN 0
ELSE eligible_amount 
END as eligible_amount,

CASE 
WHEN global_total > 30.0 AND global_total - eligible_amount < 30.0
-- previous global total = global_total less eligible_amount
THEN global_total - 30.0
WHEN global_total < 30.0 THEN 0
ELSE eligible_amount 
END as eligible_amount_above_cap,

CASE 
WHEN global_total > 30.0 AND global_total - eligible_amount < 30.0
-- previous global total = global_total less eligible_amount
THEN 30.0 - (global_total - eligible_amount)
WHEN global_total > 30.0 THEN 0
ELSE amount_eth
END as adjusted_amount_eth

 FROM the_finalized_transactions_full_table

) as query1

GROUP BY from_address
ORDER BY 1;

-- running view of eligible addresses from non-finalized tables
CREATE VIEW eligible_addresses AS

-- query name eligible addresses (new version for topping tx capped up to 30 exactly)

SELECT * FROM address_totals
WHERE eligible_amount > 0;

-- running view of eligible addresses from finalized tables. note: the private_results views provide more rich results here
CREATE VIEW eligible_addresses_finalized AS

-- query name eligible addresses (new version for topping tx capped up to 30 exactly)

SELECT * FROM address_totals_finalized
WHERE eligible_amount > 0;

CREATE VIEW donation_stats AS
-- query name donation stats

WITH temp AS (
SELECT 
SUM(amount_eth) AS total_eth_donated,
COUNT(distinct from_address) AS total_participants,
COUNT(*) AS total_donations
FROM the_full_table 
),
temp2 AS (
SELECT
--the following single stat is a little approximative and have room for improvement in some areas
COUNT(*) AS eligible_donations_approximative,
COUNT(distinct from_address) AS eligible_addresses

FROM the_full_table
WHERE eligible_amount > 0 AND
global_total - amount_eth < 30
)

SELECT
    LEAST(
        (SELECT MAX(global_total) FROM the_full_table),
        30.0
    ) as eligible_total_eth,
(SELECT total_eth_donated from temp),

    cutoff.block_number as cutoff_block,
    cutoff.tx_index as cutoff_tx_index,

(SELECT total_participants FROM temp),
(SELECT total_donations FROM temp),
(SELECT eligible_donations_approximative FROM temp2),
(SELECT eligible_addresses FROM temp2)

FROM (
    SELECT *
    FROM the_full_table
    WHERE global_total >= 30
    ORDER BY block_number, tx_index
    LIMIT 1
) cutoff
UNION
SELECT (SELECT MAX(global_total) FROM the_full_table) as eligible_total_eth, 
(SELECT total_eth_donated FROM temp),
999999999999 as cutoff_block, 1 as cutoff_tx_index,
(SELECT total_participants FROM temp),
(SELECT total_donations FROM temp),
(SELECT eligible_donations_approximative FROM temp2),
(SELECT eligible_addresses FROM temp2)

WHERE (SELECT COUNT(*) FROM
(SELECT *
    FROM the_full_table
    WHERE global_total >= 30
    ORDER BY block_number, tx_index
    LIMIT 1) cutoff1)
 < 1;

CREATE VIEW donation_stats_finalized AS
-- query name donation stats finalized

WITH temp AS (
SELECT 
SUM(amount_eth) AS total_eth_donated,
COUNT(distinct from_address) AS total_participants,
COUNT(*) AS total_donations
FROM the_finalized_transactions_full_table
),
temp2 AS (
SELECT
--the following single stat is a little approximative and have room for improvement in some areas
COUNT(*) AS eligible_donations_approximative,
COUNT(distinct from_address) AS eligible_addresses

FROM the_finalized_transactions_full_table
WHERE eligible_amount > 0 AND 
global_total - amount_eth < 30
)

SELECT
    LEAST(
        (SELECT MAX(global_total) FROM the_finalized_transactions_full_table),
        30.0
    ) as eligible_total_eth,
(SELECT total_eth_donated from temp),

    cutoff.block_number as cutoff_block,
    cutoff.tx_index as cutoff_tx_index,

(SELECT total_participants FROM temp),
(SELECT total_donations FROM temp),
(SELECT eligible_donations_approximative FROM temp2),
(SELECT eligible_addresses FROM temp2)

FROM (
    SELECT *
    FROM the_finalized_transactions_full_table
    WHERE global_total >= 30
    ORDER BY block_number, tx_index
    LIMIT 1
) cutoff
UNION
SELECT (SELECT MAX(global_total) FROM the_finalized_transactions_full_table) as eligible_total_eth, 
(SELECT total_eth_donated FROM temp),
999999999999 as cutoff_block, 1 as cutoff_tx_index,
(SELECT total_participants FROM temp),
(SELECT total_donations FROM temp),
(SELECT eligible_donations_approximative FROM temp2),
(SELECT eligible_addresses FROM temp2)

WHERE (SELECT COUNT(*) FROM
(SELECT *
    FROM the_finalized_transactions_full_table
    WHERE global_total >= 30
    ORDER BY block_number, tx_index
    LIMIT 1) cutoff1)
 < 1;

CREATE VIEW filtered_etherscan_not_in_db AS

-- query name #tag
SELECT id, transaction_hash, from_address, amount_eth, namada_key, timestamp, created_at, block_number, tx_index FROM     etherscan_transactions_all WHERE 
lower(transaction_hash) NOT IN (
SELECT lower(transaction_hash) from donations_finalized

);

--eligible addresses within drop rules as recorded in db and address totals finalized table
CREATE VIEW private_result_eligible_addresses_finalized_in_db AS

-- query name suggested eligible addresses (new version for topping tx capped up to 30 exactly)
WITH temp AS (
  SELECT SUM(eligible_amount) as total_eligible_eth FROM address_totals_finalized
)

SELECT 
    from_address, 
    tnam, 
    eligible_amount,
    eligible_amount / (SELECT total_eligible_eth FROM temp) AS fraction,
    1000000 * (eligible_amount / (SELECT total_eligible_eth FROM temp)) AS suggested_nam,
    eligible_amount / 30.0 AS predicted_fraction,
    1000000 * (eligible_amount / 30.0) AS predicted_suggested_nam
FROM address_totals_finalized
WHERE eligible_amount > 0;

--addresses in db who would otherwise have been eligible within contest rules with specified amounts if they had not been submitted after global cap was reached
CREATE VIEW private_result_above_cap_addresses_in_db AS

-- query name suggested eligible addresses (new version for topping tx capped up to 30 exactly)
WITH temp AS (
  SELECT SUM(eligible_above_cap) as total_eligible_above FROM address_totals_finalized
)

SELECT 
    from_address,
    tnam,
    eligible_above_cap,
    eligible_above_cap / 30.0 AS fraction,
    1000000 * (eligible_above_cap / 30.0) AS suggested_nam
FROM address_totals_finalized
WHERE eligible_above_cap > 0;

--addresses which were not recorded in db (presumably as lacking proper tnam in memo) but did donate within the period we scraped for in etherscan_transactions_all and are not in the abovementioned categories
CREATE VIEW private_result_addresses_not_in_db AS

-- The 0.01 conditions in this view are unsafe and were introduced as a temporary solution for the data in Donor Drop 1.
-- TODO: If this view gets used, it will need a revision.

WITH temp AS (
  SELECT SUM(amount_eth) AS total_sum
  FROM filtered_etherscan_not_in_db

  --this condition is technically not safe and adapted to the data we know currently are in our db. needs revision
  WHERE amount_eth > 0.01
)

 SELECT 
    q1.from_address,
    total_eth,
    COALESCE(unaccounted_addresses.namada_key, q1.namada_key) AS tnam,
    unaccounted_addresses.sig_hash,
    total_eth / 30 AS fraction,
    1000000 * (total_eth / 30) AS suggested_nam

   FROM (
    SELECT 
        from_address,
        SUM(amount_eth) AS total_eth,
        (SELECT total_sum FROM temp),
        MAX(namada_key) AS namada_key
    FROM filtered_etherscan_not_in_db
        
    --unsafe. for current data only
    WHERE amount_eth > 0.01
    
    GROUP BY from_address, namada_key) AS q1

LEFT JOIN unaccounted_addresses 
ON q1.from_address = unaccounted_addresses.from_address;