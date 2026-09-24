CREATE TABLE orders
(
    id          VARCHAR(64)              NOT NULL PRIMARY KEY,
    customer_id VARCHAR(128)             NOT NULL,
    amount      NUMERIC(19, 2)           NOT NULL,
    status      VARCHAR(20)              NOT NULL,
    version     BIGINT                   NOT NULL,
    created_at  TIMESTAMP WITH TIME ZONE NOT NULL,
    updated_at  TIMESTAMP WITH TIME ZONE NOT NULL
);
