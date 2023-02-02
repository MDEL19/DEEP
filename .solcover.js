module.exports = {
  skipFiles: [
    "test",
    "bls/lib",
    //solc-coverage fails to compile our Manager module.
    "gnosis",
    "utils/Exec.sol"
  ],
  configureYulOptimizer: true,
};
