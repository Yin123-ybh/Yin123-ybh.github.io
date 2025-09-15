---
title: "Redisson 可重入锁原理详解"
date: 2025-09-14
draft: false
tags: ["Java", " redission可重入锁", "Redis"]
categories: ["可重入锁原理详解"]
description: "通俗介绍redission可重入锁原理和普通分布式锁不可重入性"
---
# Redisson 可重入锁原理详解

## 1. 为什么需要可重入锁？

在日常开发中，**锁** 是保证线程安全的重要手段。但有时候，一个线程在持有锁时，会调用另一个也需要同一把锁的方法，这时问题就来了：

- 如果锁 **不可重入**，线程在第二次尝试加锁时会失败，因为锁已经存在，它相当于 **把自己卡死了**。
- 如果锁 **可重入**，同一个线程可以多次获取这把锁，直到最后释放时才真正解锁。

所以，可重入锁的意义在于：**避免同一线程因为方法嵌套调用而死锁**。

---

## 2. 普通分布式锁的问题

最简单的分布式锁通常用 Redis 的 `SETNX` 实现：

```redis
SET key value NX EX 30
```

- `NX` 表示如果 key 不存在才设置，保证原子性。
- `EX 30` 设置过期时间，防止死锁。

### 问题出在哪里？

当一个线程已经持有锁时，如果在方法嵌套中再次尝试获取锁：

1. Redis 发现 key 已存在，直接返回失败。
2. 虽然是 **同一个线程** 想再次获取锁，但因为锁实现里只区分 "有锁 / 无锁"，并不会识别线程。
3. 结果就是：**自己把自己锁死了**。

---

## 3. Redisson 的改进（可重入实现）

Redisson 在 value 的存储上做了改进，它并不是简单的字符串，而是一个 **Hash 结构**：

```
lockKey -> {
   threadId : reentrantCount
}
```

- **threadId**：唯一标识某个 JVM 里的某个线程（一般是 UUID:threadId）。
- **reentrantCount**：记录这个线程持有锁的次数。

这样就可以支持 **可重入** 了。

---

## 4. 执行流程举例

假设我们有两个方法：

```java
public void methodA() {
    lock.lock();
    try {
        methodB();
    } finally {
        lock.unlock();
    }
}

public void methodB() {
    lock.lock();
    try {
        // 执行逻辑
    } finally {
        lock.unlock();
    }
}
```

### 4.1 第一次加锁（methodA）

- Redis 里还没有 `lockKey`。
- Redisson 会写入：
  ```
  lockKey -> { "UUID:thread-1" : 1 }
  ```
- 表示线程 `thread-1` 第一次获取锁，重入次数 = 1。

### 4.2 第二次加锁（methodB）

- Redis 发现 `lockKey` 已存在，但 owner 是 **同一个线程**。
- 允许重入，计数 +1：
  ```
  lockKey -> { "UUID:thread-1" : 2 }
  ```

### 4.3 methodB 执行完释放锁

- 调用 `unlock()`，计数 -1：
  ```
  lockKey -> { "UUID:thread-1" : 1 }
  ```
- 锁仍然由当前线程持有。

### 4.4 methodA 执行完释放锁

- 再次调用 `unlock()`，计数 -1 → 变成 0。
- Redisson 删除 `lockKey`：
  ```
  lockKey 删除
  ```
- 此时锁才真正释放，其他线程才有机会获取。

---

## 5. 通俗解释

用通俗的话再描述一次：

假如一个线程调用多个方法时，第一个方法用了锁去调用第二个方法，第二个方法再次调用这个线程的锁就会失败。因为虽然锁的 key 一样，但是第二次获取锁的时候会发现锁已经存在了，就获取失败。

Redisson 在这个基础上做了改进：它在锁的 value 里加上了一个 **重入次数**，并利用 Redis Hash 结构来存储。

Hash 结构里有两个值：

- **field**：当前线程的标识（UUID + threadId）
- **value**：重入次数

执行过程是这样的：

1. **方法一第一次获取锁**：重入次数 +1，变成 1
2. **方法一调用方法二，方法二又要用锁**：重入次数再 +1，变成 2
3. **方法二执行完释放锁**：重入次数 -1，变回 1
4. **方法一执行完释放锁**：重入次数 -1，变回 0，锁才真正释放

这样就避免了同一个线程因为嵌套调用而死锁。

---

## 6. 核心实现原理

### 6.1 加锁流程

```lua
-- 加锁脚本
if (redis.call('exists', KEYS[1]) == 0) then
    redis.call('hset', KEYS[1], ARGV[2], 1);
    redis.call('pexpire', KEYS[1], ARGV[1]);
    return nil;
end;
if (redis.call('hexists', KEYS[1], ARGV[2]) == 1) then
    redis.call('hincrby', KEYS[1], ARGV[2], 1);
    redis.call('pexpire', KEYS[1], ARGV[1]);
    return nil;
end;
return redis.call('pttl', KEYS[1]);
```

### 6.2 释放锁流程

```lua
-- 释放锁脚本
if (redis.call('hexists', KEYS[1], ARGV[3]) == 0) then
    return nil;
end;
local counter = redis.call('hincrby', KEYS[1], ARGV[3], -1);
if (counter > 0) then
    redis.call('pexpire', KEYS[1], ARGV[2]);
    return 0;
else
    redis.call('del', KEYS[1]);
    redis.call('publish', KEYS[2], ARGV[1]);
    return 1;
end;
```

---

## 7. 关键特性

### 7.1 线程安全
- 使用 Lua 脚本保证原子性
- 避免竞态条件

### 7.2 自动续期
- 通过 `pexpire` 自动续期
- 防止业务执行时间过长导致锁过期

### 7.3 公平性
- 支持公平锁和非公平锁
- 通过队列机制保证获取锁的顺序

### 7.4 可重入性
- 同一线程可多次获取锁
- 通过重入计数器实现

---

## 8. 使用示例

```java
// 获取可重入锁
RLock lock = redisson.getLock("myLock");

try {
    // 尝试加锁，最多等待100秒，上锁以后10秒自动解锁
    boolean res = lock.tryLock(100, 10, TimeUnit.SECONDS);
    if (res) {
        try {
            // 业务逻辑
            doSomething();
        } finally {
            lock.unlock();
        }
    }
} catch (InterruptedException e) {
    e.printStackTrace();
}
```

---

## 9. 总结升华

1. **普通分布式锁**只关心 "有锁 / 无锁"，不关心是谁加的锁，导致 **同一线程重入时也会失败**。

2. **Redisson** 通过在 Redis 的 Hash 结构 中记录 "线程标识 + 重入计数"，让锁具备了 **可重入能力**。

3. **意义**：可重入锁避免了一个线程在嵌套调用中把自己卡死，同时对外仍然保持分布式锁的特性。

### 一句话总结：

> **Redisson 的可重入锁，本质上就是用 Redis Hash 存储线程 ID 和重入次数，直到重入次数归零才真正释放锁。**

---

## 10. 扩展阅读

- [Redisson 官方文档](https://github.com/redisson/redisson)
- [Redis 分布式锁最佳实践](https://redis.io/docs/manual/patterns/distributed-locks/)
- [Java 并发编程实战](https://book.douban.com/subject/10484692/)

---

*本文档详细介绍了 Redisson 可重入锁的实现原理，帮助开发者深入理解分布式锁的核心机制。*
