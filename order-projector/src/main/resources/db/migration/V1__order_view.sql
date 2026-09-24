CREATE TABLE order_view (
    order_id      VARCHAR(64)    PRIMARY KEY,
    customer_id   VARCHAR(64),
    amount        NUMERIC(19, 2),
    status        VARCHAR(32),
    last_version  BIGINT         NOT NULL,
    last_event_id UUID           NOT NULL,
    occurred_at   TIMESTAMPTZ    NOT NULL,
    projected_at  TIMESTAMPTZ    NOT NULL
);

CREATE INDEX idx_order_view_projected_at ON order_view (projected_at DESC);
