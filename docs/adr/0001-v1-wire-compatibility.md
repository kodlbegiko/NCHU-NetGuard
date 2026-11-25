# ADR-0001: Shared v1 wire compatibility candidate

Status: proposed, pending exact-HEAD CI and semantic review.

Use explicit public Swift constructors for the eight shared contracts and validate version and fields at trust boundaries. Preserve existing Codable names and date representation to avoid breaking current v1 fixtures. The golden JSON tests verify semantic round trips and rejection of missing or unsupported versions, without granting authority to perform actions.

Alternatives: changing to ISO8601 now would break already documented numeric-date serialization; relying on synthesized internal constructors would block independent consumers. Keep provider and persistence schemas separate. A future breaking change requires an explicit version, migration, ADR and compatibility tests.

This does not freeze the contracts or authorize network changes. Full parallel development remains locked until the contract semantic review and integration owner approval. No paid services.
