# Data for checking compatibility with Muter's verification code

- `expected-examples.json`: the positions of the mutants that the unit tests of Muter (https://github.com/muter-mutation-testing/muter, MIT License) expect, transcribed from the tests and snapshots of commit `5c854098e61d1a093ef9c4e53a5ebc6de07b3a32`. The notes inside the file are in Japanese.
- `LICENSE-muter.txt`: Muter's licence (MIT), kept here because the file above is derived from Muter's test data.

Muter's sources and sample projects (`Repositories/`, which include the third-party open-source projects BonMot and FFCParserCombinator) are **not** part of this repository. `scripts/verify-muter-fixtures.sh` fetches the commit above into `.build/external/muter` and uses it from there. Results: [docs/verification.md](../../docs/verification.md) (Japanese).
