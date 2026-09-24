-- Une instance, deux bases : côté écriture (propriétaire) et côté lecture (projections).
-- En production ce seraient des stockages distincts.
CREATE DATABASE orders_write OWNER poc;
CREATE DATABASE orders_read OWNER poc;
