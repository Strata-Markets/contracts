import { IToken } from 'dequanto/models/IToken';
import { IPlatform } from './IPlatform';
import { Addresses } from '@s/constants';

const Tokens = {
    USDe: { address: '0x4c9EDD5852cd905f086C759E8383e09bff1E68B3', decimals: 18 },
    sUSDe: {
        address: '0x9d39a5de30e57443bff2a8307a4256c8797a3497',
        decimals: 18,
    },
    eUSDe: {
        address: '0x90d2af7d622ca3141efa4d8f1f24d86e5974cc8f',
        decimals: 18,
    },
    sUSDS: { address: Addresses.eth.sUSDS, decimals: 18 },
    pUSDe: { address: Addresses.eth.pUSDe, decimals: 18 },

    USDC: { address: Addresses.eth.USDC, decimals: 6 },
    USDT: { address: Addresses.eth.USDT, decimals: 6 },

    NUSD: { address: Addresses.eth.NUSD, decimals: 18 },
    sNUSD: { address: Addresses.eth.sNUSD, decimals: 18 },

    DAI: { address: '0x6b175474e89094c44da98b954eedeac495271d0f', decimals: 18 },
    USDS: { address: '0xdC035D45d973E3EC169d2276DDab16f1e407384F', decimals: 18 },

    mHYPER: {
        address: '0x9b5528528656DBC094765E2abB79F293c21191B9',
        decimals: 18,
    },
    mM1USD: {
        address: '0xCc5C22C7A6BCC25e66726AeF011dDE74289ED203',
        decimals: 18,
    },
    mROX: {
        address: '0x67E1F506B148d0Fc95a4E3fFb49068ceB6855c05',
    },
    mKRALPHA: {
        address: '0xE70B5Eb021Dc3AF653D61fd792D8f0B60F36c493',
        decimals: 18,
    },
    // Saturn
    USDat: {
        address: '0x23238f20b894f29041f48D88eE91131C395AAa71', // sUSDat.asset() — verified on-chain
        decimals: 6,
    },
    sUSDat: {
        address: '0xD166337499E176bbC38a1FBd113Ab144e5bd2Df7',
        decimals: 18,
    },
    // Nest BlackOpal LiquidStone II
    nOPAL: {
        address: '0x119Dd7dAFf816f29D7eE47596ae5E4bdC4299165',
        decimals: 6,
    },
} as Record<string, Partial<IToken>>;

export const Eth: IPlatform = {
    Tokens: Tokens,
    Feed: {
        stalePeriodAfter: '4hours',
    },

    mhyper: {
        oracle: '0x43881B05C3BE68B2d33eb70aDdF9F666C5005f68',
        depositVault: '0xbA9FD2850965053Ffab368Df8AA7eD2486f11024',
        redemptionVault: '0x6Be2f55816efd0d91f52720f096006d63c366e98',
    },

    mm1usd: {
        oracle: '0xad316aA927c0970C2e8f0B903211D0bd19A10702',
        depositVault: '0x0f7e323103b29e1b18d521de957ed0c4c0a8189e',
        redemptionVault: '0x70ba3211f2584bf1c8a2acdf0a00dba559ce1ffa',
    },

    mrox: {
        oracle: '0x7fF56C3a31476c231e74E4F64e9d9718572B54Aa',
        depositVault: '0x511d88E64d843Ee11Bf039a3EB837393001aEDE7',
        redemptionVault: '0xc33dAdA688f224c514682Ec6Ba940888d43C4b29',
    },

    mkralpha: {
        oracle: '0x38092073c5483bA9D844cC6733976957011e8AEe',
        depositVault: '0x54602a8e47BF82073d75E0AC2aeF67F84fbCb8e4',
        redemptionVault: '0xc37eDf7d955020D547B45F762027b49947D02550',
    },

    saturn: {
        // Resolve from sUSDat on-chain: sUSDat.getWithdrawalQueue(), sUSDat.getStrcOracle()
        sUSDat: '0xD166337499E176bbC38a1FBd113Ab144e5bd2Df7',
    },
    figure: {
        navEngine: '0xfed839b6ba09c1abf4c768aba0eca50746e4eca9',
        feedVerifier: '0xdF4ab20fA7752Be52E41e42F1FD667f37964d6a3',
        yieldVault: '0x6aD038cA6C04e885630851278ca0a856Ad9a66Cc',
        stakingVault: '0x19ebb35279a16207ec4ba82799cc64715065f7f6',
        primeFeed: '0xf17C0EdcAA28371e9c8012D7699bF40ECF0F58d1',
    },
    nestopal: {
        nOPAL: '0x119Dd7dAFf816f29D7eE47596ae5E4bdC4299165',
        accountant: '0x2Ed2f77a961fc92F73D1087786099c39C894Ed1D',
        predicateProxy: '0xfc0c4222b3a0c9b060c0b959dec62442036b9035',
        teller: '0xA5F8e5843dd597a179453bF782844e8Bf808A90b',
        nestVault: '0xd258029cf5a177e3306e09fbea63424543a505c0',
    },
};
