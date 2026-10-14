-- Clients du bac à sable : base des fixtures /audit-pr.
CREATE TABLE customers (
    id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name       text        NOT NULL,
    email      text        NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now()
);
