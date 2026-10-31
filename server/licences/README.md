# Licence keys

`GET https://licences.lgtm.ninja/v1/licence?txn=txn_…` → `{ key, licence }` for a completed Paddle
order. The thank-you page (`lgtm.ninja/euclid/thanks/?txn=…`, opened by checkout) shows the key.

- Stateless: reads the transaction, customer and business from Paddle on each call and signs a key in the
  app's format (`Sources/EuclidCore/Licence/Licence.swift`). Ed25519 is deterministic, so the same order
  always gets the same key, and a lost key is re-fetched from the same link.
- Edition comes from the price (`PRICES` in wrangler.toml); Business seats = quantity, Personal = 1.
  Licensed to the business name, else the customer's name, else their email.
- Only `paid`/`completed` orders get a key. 10 lookups a minute per address.
- No webhook needed: nothing to store, so nothing can fall out of sync.

```sh
cd server/licences
npm test                                         # node --test, no dependencies
npx wrangler@4 deploy                            # Cloudflare login on first run
npx wrangler@4 secret put PADDLE_API_KEY         # live key, read: transactions, customers, businesses
npx wrangler@4 secret put LICENCE_PRIVATE_KEY    # from Keychain `euclid-licence` (account private-key)
```
