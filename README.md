# Cygnus LP Oracle - Balancer Weighted Pools

A fair reserves LP Oracle for Balancer WeightedPools with n tokens, Modified from Revest Finance (https://revestfinance.medium.com/dev-blog-on-the-derivation-of-a-safe-price-formula-for-balancer-pool-tokens-33e8993455d0)

<p align="center">
<img src="https://user-images.githubusercontent.com/97303883/231590227-b6affddf-1e28-4d76-a8ef-c685494cf284.png" />
</p>

Wi is the weight of the ith token, pi is the price of the ith token according to a safe-price oracle, Γ is the total supply of the LP tokens, and V is the pool invariant:
