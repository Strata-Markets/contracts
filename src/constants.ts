import { TEth } from 'dequanto/models/TEth';

export const Addresses = {
    eth: {
        USDe: "0x4c9EDD5852cd905f086C759E8383e09bff1E68B3",
        sUSDe: "0x9d39a5de30e57443bff2a8307a4256c8797a3497",
        eUSDe: "0x90d2af7d622ca3141efa4d8f1f24d86e5974cc8f",
        owner: "0xA27cA9292268ee0f0258B749f1D5740c9Bb68B50",

        sNUSD: '0x08EFCC2F3e61185D0EA7F8830B3FEc9Bfa2EE313',
        NUSD: '0xE556ABa6fe6036275Ec1f87eda296BE72C811BCE',

        // https://etherscan.io/token/0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD
        sUSDS: '0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD',
        pUSDe: '0xA62B204099277762d1669d283732dCc1B3AA96CE',
        USDC: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
        USDT: '0xdac17f958d2ee523a2206206994597c13d831ec7',
        AavePool: '0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2',

        SparkUSDCVault: '0x28B3a8fb53B741A8Fd78c0fb9A6B2393d896a43d',
    },
    hoodi: {
        USDe: "0x7054A803361640970176Edbd91992DcC52B7D235",
        sUSDe: "0x789d3D9AA2EFDda01f0402a632803158F21cCe05",
        pUSDe: '0x345CFCe350c1C6Dc653B5f2E187d4f109E8C4B95',
    }
} as Record<string, {
    USDe: TEth.Address;
    USDC?: TEth.Address;
    USDT?: TEth.Address;
    sUSDe: TEth.Address;
    sUSDS?: TEth.Address;
    pUSDe?: TEth.Address;
    owner?: TEth.Address;
    AavePool?: TEth.Address;

    NUSD?: TEth.Address;
    sNUSD?: TEth.Address;
    SparkUSDCVault?: TEth.Address;
}>;
