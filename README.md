# LendPal 白名单、买卖与质押

这个仓库放三份合约，都针对 Sepolia（链 ID `11155111`）。

- `AccessRegistry`：白名单。UUPS 代理，地址不变：`0x135Fb34eBAd72BB91932E22ff48Fa6963f0e5F9E`
- `OtcTrade`：买卖。当前正在使用的代理：`0x23F57c925Dd94cB8b8f0Ab8269FC24e830DAe0A7`
- `PledgeLoan`：质押。正在更新中。合约已经写在这个仓库，还没有部署，也还没有链上地址。

白名单仍然可以升级。当前这份买卖实现已经永久关闭升级。再改买卖规则就要重新部署，不要对正在使用的代理调用升级。质押不走买卖合约。

## 目录

- `contracts/`：白名单、买卖、质押三份正式合约
- `contracts/interfaces/`：买卖和质押用来问「在不在白名单」的接口
- `contracts/test/`：测试用的 USDT，不用于生产
- `scripts/`：部署和升级脚本
- `test/`：Foundry 测试

## 白名单

身份只有三种：超级管理员、普通管理员、普通地址。超级管理员和普通管理员在产品里都算已经准入，和白名单用户一样。

超级管理员是 `owner`。他可以添加、删除普通管理员，可以删除任何一条白名单，可以升级这份白名单合约。普通管理员默认最多 200 人。超级管理员本人不占这个名额。

普通管理员只能加入自己经手的地址，也只能删除自己加入的地址。批量加入和批量删除一次最多 50 条。其中一条不合法，整笔回滚。

`isWhitelisted` 只回答在或不在。一个地址只能被加入一次。名单里没有「谁邀请了谁」，也没有介绍人或担保额度。身份用 `roleOf`：`1` 是普通管理员，`2` 是超级管理员。

## 买卖

付 USDT 的人调用 `pay(receiver, usdtAmount, hkdAmount, orderId)`。`orderId` 就是后端订单号，例如 `S-261110-7702074f` 或 `B-261111-6a04e8b0`。格式固定 17 个字符：`S` 或 `B`，减号，6 位日期，减号，8 位小写十六进制。大写会失败。

调用前，付款人要先把测试 USDT `approve` 给这个买卖代理。`pay` 从付款人钱包转两笔：99% 给收款人，1% 给手续费地址。合约上不留 USDT。不要把 USDT 直接转到代理地址。

`getTrade(string)` 用同一串订单号读出这笔成交。历史上已经在上一份合约完成的 `S-261110-7702074f` 也能读到，不会再转一次代币。`getTrade(uint256)` 仍按数字编号读取。Blockscout 上字符串这个重载的选择器是 `0x9fa637a8`，数字那个是 `0x2db25e05`。把订单号填进数字参数会被当成无效数字。

开单和结算时，两边地址都要在白名单里。`deposit` 和 `refund` 已关闭。

手续费地址：`0x4F9064DAAE146e8F712e7C178EFeDEb6dE7BAA53`。测试 USDT：`0xaeb831366b23C6fd13aD39068017197478398e32`，名称 Test USDT，6 位小数。

当前部署：

| 角色 | 地址 |
| --- | --- |
| 正在使用的买卖代理 | `0x23F57c925Dd94cB8b8f0Ab8269FC24e830DAe0A7` |
| 这份代理的实现 | `0x9cf9E06e7081445580a39e04069B2436e60F6C23` |
| 上一本账本，已链上成交的订单从这里读 | `0x4fF61AC7FB1834A322aD4bbBD49dB70a9b7Aa1c1` |
| 更早的托管版代理，升级已关闭，不要再调用 | `0x1c0865085D32ad95C730AF0879F0642a48b732c5` |

`scripts/DeployOtcTrade.s.sol` 会再部署一份新的代理，并写入 USDT 和手续费地址。已经在用的代理不要靠这个脚本升级。

## 本地测试

依赖 Foundry。OpenZeppelin 和 forge-std 在 `lib/`。编译器 `0.8.24`，优化 200 次，Cancun。

```bash
forge test
```

## 部署

把 `.env.example` 复制成 `.env`，填入 Sepolia 的 RPC 和部署私钥。私钥不要提交。

```bash
forge script scripts/DeployAccessRegistry.s.sol --rpc-url sepolia --broadcast
forge script scripts/DeployOtcTrade.s.sol --rpc-url sepolia --broadcast
```

已经部署的白名单代理用 `scripts/UpgradeAccessRegistry.s.sol` 升级，地址保持不变。

## 质押

正在更新中。法币在线下当面交付。合约不收手续费，也不把 USDT 留在合约里。

质押方调用 `deliver(counterparty, principal, termDays, orderId)`，把整笔 USDT 从自己的钱包转给承接方。承接方之后调用 `repay(loanId)`，把同样数量的本金还给质押方。期限只能是 7、14、21、28 天。两边地址都要在白名单里。订单号只能用一次。

前 7 天免息，之后按本金每天 0.1% 计息，计息天数不超过约定期限减 7 天。利息写在 `Repaid` 事件里，给线下的法币结算看。链上归还的是本金。

调用前要先把测试 USDT `approve` 给这份质押合约。不要把 USDT 直接转到合约地址，也不要用买卖合约的 `pay` 做质押。买卖的 `deposit` 和 `refund` 已经关闭。

这份合约还没部署。部署之前，用户端的链上转账先停着。
