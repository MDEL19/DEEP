import { Wallet } from 'ethers'
import { ethers } from 'hardhat'
import { expect } from 'chai'
import {
  SimpleWallet,
  SimpleWalletDeployer__factory,
  SimpleWallet__factory,
  TestUtil,
  TestUtil__factory
} from '../typechain'
import { AddressZero, createAddress, createAccountOwner, getBalance, isDeployed, ONE_ETH } from './testutils'
import { fillUserOpDefaults, getRequestId, packUserOp, signUserOp } from './UserOp'
import { parseEther } from 'ethers/lib/utils'
import { UserOperation } from './UserOperation'

describe('SimpleWallet', function () {
  const entryPoint = '0x'.padEnd(42, '2')
  let accounts: string[]
  let testUtil: TestUtil
  let accountOwner: Wallet
  const ethersSigner = ethers.provider.getSigner()

  before(async function () {
    accounts = await ethers.provider.listAccounts()
    // ignore in geth.. this is just a sanity test. should be refactored to use a single-account mode..
    if (accounts.length < 2) this.skip()
    testUtil = await new TestUtil__factory(ethersSigner).deploy()
    accountOwner = createAccountOwner()
  })

  it('owner should be able to call transfer', async () => {
    const account = await new SimpleWallet__factory(ethers.provider.getSigner()).deploy(entryPoint, accounts[0])
    await ethersSigner.sendTransaction({ from: accounts[0], to: account.address, value: parseEther('2') })
    await account.transfer(accounts[2], ONE_ETH)
  })
  it('other account should not be able to call transfer', async () => {
    const account = await new SimpleWallet__factory(ethers.provider.getSigner()).deploy(entryPoint, accounts[0])
    await expect(account.connect(ethers.provider.getSigner(1)).transfer(accounts[2], ONE_ETH))
      .to.be.revertedWith('only owner')
  })

  it('should pack in js the same as solidity', async () => {
    const op = await fillUserOpDefaults({ sender: accounts[0] })
    const packed = packUserOp(op)
    expect(await testUtil.packUserOp(op)).to.equal(packed)
  })

  describe('#validateUserOp', () => {
    let account: SimpleWallet
    let userOp: UserOperation
    let requestId: string
    let preBalance: number
    let expectedPay: number

    const actualGasPrice = 1e9

    before(async () => {
      // that's the account of ethersSigner
      const entryPoint = accounts[2]
      account = await new SimpleWallet__factory(await ethers.getSigner(entryPoint)).deploy(entryPoint, accountOwner.address)
      await ethersSigner.sendTransaction({ from: accounts[0], to: account.address, value: parseEther('0.2') })
      const callGasLimit = 200000
      const verificationGasLimit = 100000
      const maxFeePerGas = 3e9
      const chainId = await ethers.provider.getNetwork().then(net => net.chainId)

      userOp = signUserOp(fillUserOpDefaults({
        sender: account.address,
        callGasLimit,
        verificationGasLimit,
        maxFeePerGas
      }), accountOwner, entryPoint, chainId)

      requestId = await getRequestId(userOp, entryPoint, chainId)

      expectedPay = actualGasPrice * (callGasLimit + verificationGasLimit)

      preBalance = await getBalance(account.address)
      const ret = await account.validateUserOp(userOp, requestId, AddressZero, expectedPay, { gasPrice: actualGasPrice })
      await ret.wait()
    })

    it('should pay', async () => {
      const postBalance = await getBalance(account.address)
      expect(preBalance - postBalance).to.eql(expectedPay)
    })

    it('should increment nonce', async () => {
      expect(await account.nonce()).to.equal(1)
    })
    it('should reject same TX on nonce error', async () => {
      await expect(account.validateUserOp(userOp, requestId, AddressZero, 0)).to.revertedWith('invalid nonce')
    })
    it('should reject tx with wrong signature', async () => {
      // validateUserOp doesn't check the actual UserOp for the signature, but relies on the requestId given by
      // the entrypoint
      const wrongRequestId = ethers.constants.HashZero
      await expect(account.validateUserOp(userOp, wrongRequestId, AddressZero, 0)).to.revertedWith('account: wrong signature')
    })
  })
  context('SimpleWalletDeployer', () => {
    it('sanity: check deployer', async () => {
      const ownerAddr = createAddress()
      const deployer = await new SimpleWalletDeployer__factory(ethersSigner).deploy()
      const target = await deployer.callStatic.deployAccount(entryPoint, ownerAddr, 1234)
      expect(await isDeployed(target)).to.eq(false)
      await deployer.deployAccount(entryPoint, ownerAddr, 1234)
      expect(await isDeployed(target)).to.eq(true)
    })
  })
})
