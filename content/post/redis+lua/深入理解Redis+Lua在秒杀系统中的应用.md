---
title: "深入理解 Redis + Lua 在秒杀系统中的应用"
date: 2025-09-14
draft: false
tags: ["Redis", "Lua", "秒杀系统", "高并发", "分布式锁"]
categories: ["技术"]
description: "通过完整的案例，详细讲解 Redis + Lua 脚本在秒杀活动中的使用方式，包括防超卖、限购控制等核心功能实现。"
---
# 深入理解 Redis + Lua 在秒杀系统中的应用

在高并发场景下，尤其是秒杀系统，如何保证**库存扣减的正确性**和**用户限购的准确性**，是一个非常经典的问题。  
本文将通过一个完整的案例，详细讲解 **Redis + Lua 脚本** 在秒杀活动中的使用方式。

---

## 一、背景介绍

在秒杀场景中，如果单纯依赖后端数据库进行库存扣减与用户校验，往往会产生以下问题：

1. **高并发下数据库压力过大**：大量用户同时下单，数据库容易被打爆。  
2. **超卖问题**：多个线程并发操作时，可能会出现库存被扣成负数的情况。  
3. **限购逻辑失效**：如果并发控制不好，同一用户可能绕过限购限制。  

为了解决这些问题，我们通常会 **将秒杀的核心逻辑放到 Redis 里**，利用 Redis 的高性能与 Lua 脚本的原子性，来保证数据一致性。

---

## 二、Redis Key 设计

在这个秒杀系统中，我们为每个活动设计了两个关键的 Redis Key：

### 1. 库存 Key
```bash
seckill:stock:{activityId}
```
**作用**：存放某个活动的剩余库存数量。

**示例**：
```bash
SET seckill:stock:1001 50
```
表示活动 1001 还有 50 件商品。

### 2. 参与用户 Key
```bash
seckill:participants:{activityId}
```
**作用**：存放某个活动所有用户的购买记录（哈希表）。

**示例**：
```bash
HSET seckill:participants:1001 12345 1
HSET seckill:participants:1001 67890 2
```
表示：
- 用户 12345 已经购买 1 件
- 用户 67890 已经购买 2 件

---

## 三、Java 代码调用 Lua 脚本

在后端中，调用 Lua 脚本的方式如下：

```java
String stockKey = seckillPrefix + "stock:" + activityId;
String participantsKey = seckillPrefix + "participants:" + activityId;

DefaultRedisScript<List> script = new DefaultRedisScript<>();
script.setScriptSource(new ResourceScriptSource(new ClassPathResource("seckill_participate.lua")));
script.setResultType(List.class);

List<String> keys = Arrays.asList(stockKey, participantsKey);
List<Object> args = Arrays.asList(
    userId.toString(),
    quantity.toString(),
    activity.getPerUserLimit().toString()
);

List result = redisTemplate.execute(script, keys, args.toArray());
```

### 参数传递说明

这里需要重点理解的有两部分：

**keys → 传递给 Lua 的 Redis Key，脚本里用 KEYS[] 访问：**
- `KEYS[1] = "seckill:stock:1001"` （这个活动的库存）
- `KEYS[2] = "seckill:participants:1001"` （记录了这个活动所有用户的购买记录）

**args → 附加参数，脚本里用 ARGV[] 访问：**
- `ARGV[1] = userId` （当前用户 ID）
- `ARGV[2] = quantity` （本次购买数量）
- `ARGV[3] = perUserLimit` （每人限购数量）

---

## 四、Lua 脚本逻辑详解

Lua 脚本具有原子性，在 Redis 中执行时不会被打断，非常适合秒杀场景。

典型的 `seckill_participate.lua` 脚本如下：

```lua
-- 获取参数
local stock = tonumber(redis.call("GET", KEYS[1]))
local userId = ARGV[1]
local quantity = tonumber(ARGV[2])
local perUserLimit = tonumber(ARGV[3])

-- 查询用户已购买数量
local userBought = tonumber(redis.call("HGET", KEYS[2], userId) or "0")

-- 1. 校验是否超过个人限购
if userBought + quantity > perUserLimit then
    return {0, "超过个人限购"}
end

-- 2. 校验库存是否足够
if stock < quantity then
    return {0, "库存不足"}
end

-- 3. 扣减库存
redis.call("DECRBY", KEYS[1], quantity)

-- 4. 更新用户购买数量
redis.call("HINCRBY", KEYS[2], userId, quantity)

-- 5. 返回成功
return {1, "成功"}
```

### 脚本执行流程详解

让我们逐步分析这个脚本的执行过程：

#### 1. 参数接收
```lua
local userId = ARGV[1]                    -- 接收用户ID
local quantity = tonumber(ARGV[2])        -- 接收购买数量
local perUserLimit = tonumber(ARGV[3])    -- 接收限购数量
```
后端通过 `redisTemplate.execute(...)` 传入这些 ARGV 参数给 Lua 脚本，脚本接收每个参数。

#### 2. 查询用户购买记录
```lua
local userBought = tonumber(redis.call("HGET", KEYS[2], userId) or "0")
```
**这段代码的作用**：查询当前 userId 的购买记录。

**原理**：因为传入了 `participantsKey`（这个活动的用户购买记录）和 `userId`（这个用户），就可以根据 `userId` 在 `participantsKey` 里面查出对应的用户购买记录。

#### 3. 限购校验
```lua
if userBought + quantity > perUserLimit then
    return {0, "超过个人限购"}
end
```
**判断逻辑**：用户目前已购买数 + 新购买数 quantity 是否大于最大购买量 perUserLimit。

- 如果是，返回 `{0, "超过个人限购"}`
- 如果不是，继续下一步

#### 4. 库存校验
```lua
if stock < quantity then
    return {0, "库存不足"}
end
```
检查库存是否足够，如果不够，则返回 `{0, "库存不足"}`。

#### 5. 执行购买操作
```lua
-- 扣减库存
redis.call("DECRBY", KEYS[1], quantity)

-- 记录用户购买数量
redis.call("HINCRBY", KEYS[2], userId, quantity)
```
如果库存足够，则：
- 扣减库存：`DECRBY` 命令将库存减少 quantity 数量
- 记录用户购买数量：`HINCRBY` 命令将用户的购买记录增加 quantity 数量

#### 6. 返回成功
```lua
return {1, "成功"}
```
最后返回 `{1, "成功"}`，表示购买成功。

---

## 五、执行流程示例

我们以用户 12345 参与活动 1001 为例，假设初始库存为 10，限购为 3：

### 第一次购买（买 2 件）

**输入参数：**
- `KEYS[1] = seckill:stock:1001`
- `KEYS[2] = seckill:participants:1001`
- `ARGV[1] = "12345"`
- `ARGV[2] = "2"`
- `ARGV[3] = "3"`

**脚本执行：**
1. `userBought = 0`（没买过）
2. `stock = 10`，足够
3. 扣减库存：`DECRBY seckill:stock:1001 2` → 库存变 8
4. 更新购买记录：`HINCRBY seckill:participants:1001 12345 2` → 用户买了 2 件
5. 返回 `{1, "成功"}`

### 第二次购买（再买 2 件）

**输入参数：**
- `ARGV[1] = "12345"`
- `ARGV[2] = "2"`
- `ARGV[3] = "3"`

**脚本执行：**
1. `userBought = 2`（上次买了 2 件）
2. 本次要买 2 件，总数 = 4 > 限购 3
3. 返回 `{0, "超过个人限购"}`

---

## 六、核心优势

通过 Redis Key 设计 + Lua 脚本原子执行，我们实现了以下目标：

### 1. 防止超卖
库存扣减和用户购买记录更新在同一个脚本里完成，保证了原子性。

### 2. 限购控制
利用哈希表存储用户购买记录，结合 Lua 脚本校验，避免了用户绕过限购。

### 3. 高并发性能
逻辑全部在 Redis 内部执行，不依赖数据库事务，性能极高。

### 4. 数据一致性
Lua 脚本的原子性保证了所有操作要么全部成功，要么全部失败。

---

## 七、实际应用场景

这种方式是很多电商平台在秒杀场景中的标准做法，也是分布式系统里常见的"数据库削峰"与"Redis 限流"的结合应用。

### 适用场景
- 秒杀活动
- 限时抢购
- 限量商品销售
- 优惠券发放
- 积分兑换

### 技术特点
- **高性能**：Redis 内存操作，响应速度快
- **原子性**：Lua 脚本保证操作原子性
- **可扩展**：支持分布式部署
- **可靠性**：避免超卖和重复购买

---

## 八、延伸思考

### 1. 退款退货支持
如果要支持退款退货，需要在 Lua 脚本里增加库存回滚逻辑：

```lua
-- 退款时回滚库存
redis.call("INCRBY", KEYS[1], quantity)
-- 减少用户购买记录
redis.call("HINCRBY", KEYS[2], userId, -quantity)
```

### 2. 分片存储优化
如果活动商品数量非常大，可以考虑分片存储库存，进一步提高并发性能：

```lua
-- 根据用户ID进行分片
local shardKey = "seckill:stock:" .. activityId .. ":" .. (userId % 10)
```

### 3. 异步处理
在真实生产环境中，还需要配合消息队列（MQ）和异步下单，以保证后续数据库写入的可靠性。
详情可前往此处了解https://yin123-ybh.github.io/p/异步秒杀系统深度解析含redis预扣库存与消息队列实现/

### 4. 监控和告警
- 监控 Redis 性能指标
- 设置库存告警阈值
- 记录用户购买行为日志

---

## 九、总结

Redis + Lua 脚本在秒杀系统中的应用，通过以下方式解决了高并发场景下的核心问题：

1. **利用 Redis 的高性能**：将核心逻辑从数据库转移到内存
2. **保证操作的原子性**：Lua 脚本确保所有操作要么全部成功，要么全部失败
3. **实现精确的限购控制**：通过哈希表记录用户购买历史
4. **避免超卖问题**：库存扣减和用户记录更新在同一脚本中完成

这种方案不仅适用于秒杀系统，在需要高并发、强一致性的场景中都有广泛应用价值。

---

*以上就是关于秒杀系统中 Redis + Lua 脚本的完整应用解析。通过深入理解这些核心概念，你就能在实际项目中灵活运用这些技术，构建出高性能、高可靠的分布式系统。*
