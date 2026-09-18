import "@0xweb/hardhat";

const config = {
  solidity: {
      version: "0.8.28",
      settings: {
          optimizer: {
              enabled: true,
              runs: 200
          },
          viaIR: true
      }
  },
  networks: {
    hardhat: {
        chainId: 1337,
        allowUnlimitedContractSize: true,
    },
    localhost: {
        chainId: 1337
    }
  },
  etherscan: {
    apiKey: {
      eth: process.env.ETHERSCAN_API_KEY,
      hoodi: process.env.ETHERSCAN_API_KEY,
    },
    customChains: [
      {
        network: "hoodi",
        chainId: 560048,
        urls: {
          apiURL: "https://api-hoodi.etherscan.io/api",
          browserURL: "https://hoodi.etherscan.io"
        }
      },
      {
        network: "eth",
        chainId: 1,
        urls: {
          apiURL: "https://api.etherscan.io/api",
          browserURL: "https://etherscan.io"
        }
      }
    ]
  }

};

export default config;
