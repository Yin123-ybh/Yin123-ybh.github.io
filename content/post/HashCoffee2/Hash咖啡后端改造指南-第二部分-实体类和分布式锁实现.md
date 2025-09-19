---
title: "Hash咖啡项目后端改造指南 - 第二部分：实体类和分布式锁实现"
date: 2025-01-14
draft: false
tags: ["Java", "Spring Boot", "Redisson", "Lua脚本", "分布式锁", "实体类设计"]
categories: ["后端开发"]
description: "详细讲解秒杀系统实体类设计、DTO创建、Mapper接口实现和基于Redisson的分布式锁防超卖机制"
---

# Hash咖啡项目后端改造指南 - 第二部分：实体类和分布式锁实现

## 目录
1. [实体类设计](#实体类设计)
2. [DTO类创建](#dto类创建)
3. [Mapper接口实现](#mapper接口实现)
4. [分布式锁服务](#分布式锁服务)
5. [Lua脚本实现](#lua脚本实现)
6. [服务层增强](#服务层增强)

---

## 实体类设计

### 1. 秒杀参与记录实体

**创建 `sky-pojo/src/main/java/com/sky/entity/SeckillParticipant.java`：**

```java
package com.sky.entity;

import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;
import java.io.Serializable;
import java.time.LocalDateTime;

/**
 * 秒杀参与记录表
 */
@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
public class SeckillParticipant implements Serializable {
    private static final long serialVersionUID = 1L;
    
    /**
     * 主键ID
     */
    private Long id;
    
    /**
     * 秒杀活动ID
     */
    private Long activityId;
    
    /**
     * 用户ID
     */
    private Long userId;
    
    /**
     * 参与数量
     */
    private Integer quantity;
    
    /**
     * 状态：0-待处理，1-成功，2-失败
     */
    private Integer status;
    
    /**
     * 创建时间
     */
    private LocalDateTime createTime;
    
    /**
     * 更新时间
     */
    private LocalDateTime updateTime;
}
```

### 2. 秒杀订单实体

**创建 `sky-pojo/src/main/java/com/sky/entity/SeckillOrder.java`：**

```java
package com.sky.entity;

import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;
import java.io.Serializable;
import java.math.BigDecimal;
import java.time.LocalDateTime;

/**
 * 秒杀订单表
 */
@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
public class SeckillOrder implements Serializable {
    private static final long serialVersionUID = 1L;
    
    /**
     * 主键ID
     */
    private Long id;
    
    /**
     * 秒杀活动ID
     */
    private Long activityId;
    
    /**
     * 用户ID
     */
    private Long userId;
    
    /**
     * 商品ID
     */
    private Long dishId;
    
    /**
     * 购买数量
     */
    private Integer quantity;
    
    /**
     * 秒杀价格
     */
    private BigDecimal seckillPrice;
    
    /**
     * 总金额
     */
    private BigDecimal totalAmount;
    
    /**
     * 订单状态：0-待支付，1-已支付，2-已取消
     */
    private Integer status;
    
    /**
     * 创建时间
     */
    private LocalDateTime createTime;
    
    /**
     * 更新时间
     */
    private LocalDateTime updateTime;
}
```

### 3. 库存扣减记录实体

**创建 `sky-pojo/src/main/java/com/sky/entity/SeckillStockLog.java`：**

```java
package com.sky.entity;

import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;
import java.io.Serializable;
import java.time.LocalDateTime;

/**
 * 库存扣减记录表
 */
@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
public class SeckillStockLog implements Serializable {
    private static final long serialVersionUID = 1L;
    
    /**
     * 主键ID
     */
    private Long id;
    
    /**
     * 秒杀活动ID
     */
    private Long activityId;
    
    /**
     * 用户ID
     */
    private Long userId;
    
    /**
     * 扣减数量
     */
    private Integer quantity;
    
    /**
     * 扣减前库存
     */
    private Integer beforeStock;
    
    /**
     * 扣减后库存
     */
    private Integer afterStock;
    
    /**
     * 状态：1-成功，0-失败
     */
    private Integer status;
    
    /**
     * 创建时间
     */
    private LocalDateTime createTime;
}
```

---

## DTO类创建

### 1. 秒杀参与DTO

**创建 `sky-pojo/src/main/java/com/sky/dto/SeckillParticipateDTO.java`：**

```java
package com.sky.dto;

import lombok.Data;
import java.io.Serializable;

/**
 * 秒杀参与DTO
 */
@Data
public class SeckillParticipateDTO implements Serializable {
    private static final long serialVersionUID = 1L;
    
    /**
     * 活动ID
     */
    private Long activityId;
    
    /**
     * 用户ID
     */
    private Long userId;
    
    /**
     * 参与数量
     */
    private Integer quantity;
}
```

### 2. 秒杀订单DTO

**创建 `sky-pojo/src/main/java/com/sky/dto/SeckillOrderDTO.java`：**

```java
package com.sky.dto;

import lombok.Data;
import java.io.Serializable;
import java.math.BigDecimal;

/**
 * 秒杀订单DTO
 */
@Data
public class SeckillOrderDTO implements Serializable {
    private static final long serialVersionUID = 1L;
    
    /**
     * 活动ID
     */
    private Long activityId;
    
    /**
     * 用户ID
     */
    private Long userId;
    
    /**
     * 商品ID
     */
    private Long dishId;
    
    /**
     * 购买数量
     */
    private Integer quantity;
    
    /**
     * 秒杀价格
     */
    private BigDecimal seckillPrice;
    
    /**
     * 总金额
     */
    private BigDecimal totalAmount;
}
```

---

## Mapper接口实现

### 1. 秒杀参与记录Mapper

**创建 `sky-server/src/main/java/com/sky/mapper/SeckillParticipantMapper.java`：**

```java
package com.sky.mapper;

import com.sky.annotation.AutoFill;
import com.sky.entity.SeckillParticipant;
import com.sky.enumeration.OperationType;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

@Mapper
public interface SeckillParticipantMapper {
    
    /**
     * 插入秒杀参与记录
     */
    @AutoFill(value = OperationType.INSERT)
    void insert(SeckillParticipant participant);
    
    /**
     * 根据用户和活动查询参与记录
     */
    SeckillParticipant getByUserAndActivity(@Param("userId") Long userId, 
                                           @Param("activityId") Long activityId);
    
    /**
     * 更新参与状态
     */
    @AutoFill(value = OperationType.UPDATE)
    void updateStatus(@Param("id") Long id, @Param("status") Integer status);
    
    /**
     * 检查用户是否已参与
     */
    int checkUserParticipated(@Param("userId") Long userId, 
                             @Param("activityId") Long activityId);
}
```

### 2. 秒杀订单Mapper

**创建 `sky-server/src/main/java/com/sky/mapper/SeckillOrderMapper.java`：**

```java
package com.sky.mapper;

import com.sky.annotation.AutoFill;
import com.sky.entity.SeckillOrder;
import com.sky.enumeration.OperationType;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

import java.util.List;

@Mapper
public interface SeckillOrderMapper {
    
    /**
     * 插入秒杀订单
     */
    @AutoFill(value = OperationType.INSERT)
    void insert(SeckillOrder order);
    
    /**
     * 根据ID查询订单
     */
    SeckillOrder getById(@Param("id") Long id);
    
    /**
     * 更新订单状态
     */
    @AutoFill(value = OperationType.UPDATE)
    void updateStatus(@Param("id") Long id, @Param("status") Integer status);
    
    /**
     * 根据用户ID查询订单列表
     */
    List<SeckillOrder> getByUserId(@Param("userId") Long userId);
    
    /**
     * 根据活动ID查询订单列表
     */
    List<SeckillOrder> getByActivityId(@Param("activityId") Long activityId);
}
```

### 3. 库存扣减记录Mapper

**创建 `sky-server/src/main/java/com/sky/mapper/SeckillStockLogMapper.java`：**

```java
package com.sky.mapper;

import com.sky.annotation.AutoFill;
import com.sky.entity.SeckillStockLog;
import com.sky.enumeration.OperationType;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

import java.util.List;

@Mapper
public interface SeckillStockLogMapper {
    
    /**
     * 插入库存扣减记录
     */
    @AutoFill(value = OperationType.INSERT)
    void insert(SeckillStockLog stockLog);
    
    /**
     * 根据活动ID查询库存记录
     */
    List<SeckillStockLog> getByActivityId(@Param("activityId") Long activityId);
    
    /**
     * 根据用户ID查询库存记录
     */
    List<SeckillStockLog> getByUserId(@Param("userId") Long userId);
}
```

### 4. Mapper XML文件

**创建 `sky-server/src/main/resources/mapper/SeckillParticipantMapper.xml`：**

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<!DOCTYPE mapper PUBLIC "-//mybatis.org//DTD Mapper 3.0//EN"
        "http://mybatis.org/dtd/mybatis-3-mapper.dtd" >
<mapper namespace="com.sky.mapper.SeckillParticipantMapper">

    <insert id="insert" useGeneratedKeys="true" keyProperty="id">
        INSERT INTO seckill_participant 
        (activity_id, user_id, quantity, status, create_time, update_time)
        VALUES 
        (#{activityId}, #{userId}, #{quantity}, #{status}, #{createTime}, #{updateTime})
    </insert>

    <select id="getByUserAndActivity" resultType="com.sky.entity.SeckillParticipant">
        SELECT * FROM seckill_participant 
        WHERE user_id = #{userId} AND activity_id = #{activityId}
    </select>

    <update id="updateStatus">
        UPDATE seckill_participant 
        SET status = #{status}, update_time = NOW() 
        WHERE id = #{id}
    </update>

    <select id="checkUserParticipated" resultType="int">
        SELECT COUNT(*) FROM seckill_participant 
        WHERE user_id = #{userId} AND activity_id = #{activityId}
    </select>

</mapper>
```

**创建 `sky-server/src/main/resources/mapper/SeckillOrderMapper.xml`：**

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<!DOCTYPE mapper PUBLIC "-//mybatis.org//DTD Mapper 3.0//EN"
        "http://mybatis.org/dtd/mybatis-3-mapper.dtd" >
<mapper namespace="com.sky.mapper.SeckillOrderMapper">

    <insert id="insert" useGeneratedKeys="true" keyProperty="id">
        INSERT INTO seckill_order 
        (activity_id, user_id, dish_id, quantity, seckill_price, total_amount, status, create_time, update_time)
        VALUES 
        (#{activityId}, #{userId}, #{dishId}, #{quantity}, #{seckillPrice}, #{totalAmount}, #{status}, #{createTime}, #{updateTime})
    </insert>

    <select id="getById" resultType="com.sky.entity.SeckillOrder">
        SELECT * FROM seckill_order WHERE id = #{id}
    </select>

    <update id="updateStatus">
        UPDATE seckill_order 
        SET status = #{status}, update_time = NOW() 
        WHERE id = #{id}
    </update>

    <select id="getByUserId" resultType="com.sky.entity.SeckillOrder">
        SELECT * FROM seckill_order 
        WHERE user_id = #{userId} 
        ORDER BY create_time DESC
    </select>

    <select id="getByActivityId" resultType="com.sky.entity.SeckillOrder">
        SELECT * FROM seckill_order 
        WHERE activity_id = #{activityId} 
        ORDER BY create_time DESC
    </select>

</mapper>
```

**创建 `sky-server/src/main/resources/mapper/SeckillStockLogMapper.xml`：**

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<!DOCTYPE mapper PUBLIC "-//mybatis.org//DTD Mapper 3.0//EN"
        "http://mybatis.org/dtd/mybatis-3-mapper.dtd" >
<mapper namespace="com.sky.mapper.SeckillStockLogMapper">

    <insert id="insert" useGeneratedKeys="true" keyProperty="id">
        INSERT INTO seckill_stock_log 
        (activity_id, user_id, quantity, before_stock, after_stock, status, create_time)
        VALUES 
        (#{activityId}, #{userId}, #{quantity}, #{beforeStock}, #{afterStock}, #{status}, #{createTime})
    </insert>

    <select id="getByActivityId" resultType="com.sky.entity.SeckillStockLog">
        SELECT * FROM seckill_stock_log 
        WHERE activity_id = #{activityId} 
        ORDER BY create_time DESC
    </select>

    <select id="getByUserId" resultType="com.sky.entity.SeckillStockLog">
        SELECT * FROM seckill_stock_log 
        WHERE user_id = #{userId} 
        ORDER BY create_time DESC
    </select>

</mapper>
```

---

## 分布式锁服务

### 1. 添加项目依赖

**修改 `sky-server/pom.xml`：**

```xml
<!-- 在现有依赖后添加以下内容 -->

<!-- Redisson 分布式锁 -->
<dependency>
    <groupId>org.redisson</groupId>
    <artifactId>redisson-spring-boot-starter</artifactId>
    <version>3.17.7</version>
</dependency>
```

### 2. 创建分布式锁服务

**创建 `sky-server/src/main/java/com/sky/service/DistributedLockService.java`：**

```java
package com.sky.service;

import org.redisson.api.RLock;
import org.redisson.api.RedissonClient;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.core.io.ClassPathResource;
import org.springframework.data.redis.core.RedisTemplate;
import org.springframework.data.redis.core.script.DefaultRedisScript;
import org.springframework.scripting.support.ResourceScriptSource;
import org.springframework.stereotype.Service;

import java.util.Arrays;
import java.util.List;
import java.util.concurrent.TimeUnit;

/**
 * 分布式锁服务
 */
@Service
public class DistributedLockService {
    
    @Autowired
    private RedissonClient redissonClient;
    
    @Autowired
    private RedisTemplate<String, Object> redisTemplate;
    
    // 秒杀参与脚本
    private final DefaultRedisScript<List> seckillParticipateScript;
    
    public DistributedLockService() {
        // 初始化秒杀参与脚本
        this.seckillParticipateScript = new DefaultRedisScript<>();
        this.seckillParticipateScript.setScriptSource(
            new ResourceScriptSource(new ClassPathResource("scripts/seckill_participate.lua"))
        );
        this.seckillParticipateScript.setResultType(List.class);
    }
    
    /**
     * 秒杀参与
     */
    public List<Object> seckillParticipate(Long activityId, Long userId, Integer quantity, Integer perUserLimit) {
        String stockKey = "seckill:stock:" + activityId;
        String participantsKey = "seckill:participants:" + activityId;
        
        List<String> keys = Arrays.asList(stockKey, participantsKey);
        Object[] args = {userId.toString(), quantity.toString(), perUserLimit.toString()};
        
        return redisTemplate.execute(seckillParticipateScript, keys, args);
    }
    
    /**
     * 获取分布式锁
     */
    public RLock getLock(String lockKey) {
        return redissonClient.getLock(lockKey);
    }
    
    /**
     * 尝试获取锁
     */
    public boolean tryLock(String lockKey, long waitTime, long leaseTime, TimeUnit unit) {
        RLock lock = redissonClient.getLock(lockKey);
        try {
            return lock.tryLock(waitTime, leaseTime, unit);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return false;
        }
    }
    
    /**
     * 释放锁
     */
    public void unlock(String lockKey) {
        RLock lock = redissonClient.getLock(lockKey);
        if (lock.isHeldByCurrentThread()) {
            lock.unlock();
        }
    }
}
```

---

## Lua脚本实现

### 1. 秒杀参与Lua脚本

**创建 `sky-server/src/main/resources/scripts/seckill_participate.lua`：**

```lua
-- 秒杀参与Lua脚本
-- KEYS[1] = seckill:stock:{activityId}
-- KEYS[2] = seckill:participants:{activityId}
-- ARGV[1] = userId
-- ARGV[2] = quantity
-- ARGV[3] = perUserLimit

-- 检查用户是否已参与
local isParticipated = redis.call('SISMEMBER', KEYS[2], ARGV[1])
if isParticipated == 1 then
    return {0, '用户已参与该活动'}
end

-- 检查库存是否充足
local stock = redis.call('GET', KEYS[1])
if not stock then
    return {0, '活动不存在'}
end

stock = tonumber(stock)
local quantity = tonumber(ARGV[2])
local perUserLimit = tonumber(ARGV[3])

if stock < quantity then
    return {0, '库存不足'}
end

if quantity > perUserLimit then
    return {0, '超过限购数量'}
end

-- 扣减库存
local newStock = redis.call('DECRBY', KEYS[1], quantity)
if newStock < 0 then
    -- 回滚库存
    redis.call('INCRBY', KEYS[1], quantity)
    return {0, '库存不足'}
end

-- 记录用户参与
redis.call('SADD', KEYS[2], ARGV[1])

-- 设置过期时间（活动结束后清理）
redis.call('EXPIRE', KEYS[2], 86400)

return {1, '参与成功', newStock}
```

### 2. Lua脚本原理解析

**为什么使用Lua脚本？**

1. **原子性**：Lua脚本在Redis中执行是原子性的，不会被其他命令打断
2. **性能**：减少网络往返次数，提高执行效率
3. **一致性**：保证多个Redis操作的原子性，避免数据不一致

**脚本执行流程：**

1. 检查用户是否已参与（使用Set集合）
2. 验证库存是否充足
3. 检查购买数量是否超过限购
4. 原子性扣减库存
5. 记录用户参与信息
6. 设置过期时间

---

## 服务层增强

### 1. 增强SeckillActivityService

**修改 `sky-server/src/main/java/com/sky/service/impl/SeckillActivityServiceImpl.java`：**

```java
package com.sky.service.impl;

import com.github.pagehelper.Page;
import com.sky.dto.SeckillActivityDTO;
import com.sky.dto.SeckillActivityPageQueryDTO;
import com.sky.entity.SeckillActivity;
import com.sky.entity.SeckillOrder;
import com.sky.entity.SeckillParticipant;
import com.sky.entity.SeckillStockLog;
import com.sky.mapper.SeckillActivityMapper;
import com.sky.mapper.SeckillOrderMapper;
import com.sky.mapper.SeckillParticipantMapper;
import com.sky.mapper.SeckillStockLogMapper;
import com.sky.service.DistributedLockService;
import com.sky.service.SeckillActivityService;
import com.sky.vo.SeckillStatisticsVO;
import lombok.extern.slf4j.Slf4j;
import org.redisson.api.RLock;
import org.springframework.beans.BeanUtils;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.data.redis.core.RedisTemplate;
import org.springframework.scheduling.annotation.Async;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.List;
import java.util.concurrent.TimeUnit;

@Service
@Slf4j
public class SeckillActivityServiceImpl implements SeckillActivityService {

    @Autowired
    private SeckillActivityMapper seckillActivityMapper;
    
    @Autowired
    private SeckillParticipantMapper seckillParticipantMapper;
    
    @Autowired
    private SeckillOrderMapper seckillOrderMapper;
    
    @Autowired
    private SeckillStockLogMapper seckillStockLogMapper;
    
    @Autowired
    private DistributedLockService distributedLockService;
    
    @Autowired
    private RedisTemplate<String, Object> redisTemplate;

    @Override
    public Page<SeckillActivity> pageQuery(SeckillActivityPageQueryDTO seckillActivityPageQueryDTO) {
        return seckillActivityMapper.pageQuery(seckillActivityPageQueryDTO);
    }

    @Override
    public SeckillActivity getById(Long id) {
        return seckillActivityMapper.getById(id);
    }

    @Override
    @Transactional
    public void save(SeckillActivityDTO seckillActivityDTO) {
        SeckillActivity seckillActivity = new SeckillActivity();
        BeanUtils.copyProperties(seckillActivityDTO, seckillActivity);
        seckillActivity.setSoldCount(0);
        seckillActivityMapper.insert(seckillActivity);
        
        // 初始化Redis库存
        String stockKey = "seckill:stock:" + seckillActivity.getId();
        redisTemplate.opsForValue().set(stockKey, seckillActivity.getStock());
        
        log.info("秒杀活动创建成功，活动ID：{}，库存：{}", seckillActivity.getId(), seckillActivity.getStock());
    }

    @Override
    @Transactional
    public void update(SeckillActivityDTO seckillActivityDTO) {
        SeckillActivity seckillActivity = new SeckillActivity();
        BeanUtils.copyProperties(seckillActivityDTO, seckillActivity);
        seckillActivityMapper.update(seckillActivity);
        
        // 更新Redis库存
        String stockKey = "seckill:stock:" + seckillActivity.getId();
        redisTemplate.opsForValue().set(stockKey, seckillActivity.getStock());
    }

    @Override
    public void deleteById(Long id) {
        seckillActivityMapper.deleteById(id);
        
        // 删除Redis库存
        String stockKey = "seckill:stock:" + id;
        redisTemplate.delete(stockKey);
    }

    @Override
    public void updateStatus(Long id, Integer status) {
        seckillActivityMapper.updateStatus(id, status);
    }

    @Override
    public List<SeckillStatisticsVO> getStatistics(LocalDateTime startTime, LocalDateTime endTime) {
        return seckillActivityMapper.getStatistics(startTime, endTime);
    }

    @Override
    public List<SeckillActivity> getCurrentActivities() {
        return seckillActivityMapper.getCurrentActivities(LocalDateTime.now());
    }

    @Override
    public boolean reduceStock(Long id, Integer quantity) {
        return seckillActivityMapper.reduceStock(id, quantity) > 0;
    }

    @Override
    public void increaseSoldCount(Long id, Integer quantity) {
        seckillActivityMapper.increaseSoldCount(id, quantity);
    }
    
    /**
     * 参与秒杀活动
     */
    @Override
    @Transactional
    public String participateSeckill(Long activityId, Long userId, Integer quantity) {
        // 1. 获取活动信息
        SeckillActivity activity = getById(activityId);
        if (activity == null) {
            return "活动不存在";
        }
        
        // 2. 检查活动状态
        if (activity.getStatus() != 1) {
            return "活动已禁用";
        }
        
        LocalDateTime now = LocalDateTime.now();
        if (now.isBefore(activity.getStartTime())) {
            return "活动未开始";
        }
        if (now.isAfter(activity.getEndTime())) {
            return "活动已结束";
        }
        
        // 3. 使用分布式锁防止重复参与
        String lockKey = "seckill:db:lock:" + activityId;
        RLock lock = distributedLockService.getLock(lockKey);
        
        try {
            if (lock.tryLock(10, 30, TimeUnit.SECONDS)) {
                // 4. 执行Lua脚本
                List<Object> result = distributedLockService.seckillParticipate(
                    activityId, userId, quantity, activity.getPerUserLimit()
                );
                
                if (result != null && result.size() > 0) {
                    Integer success = (Integer) result.get(0);
                    if (success == 1) {
                        // 5. 记录参与记录
                        SeckillParticipant participant = SeckillParticipant.builder()
                                .activityId(activityId)
                                .userId(userId)
                                .quantity(quantity)
                                .status(1)
                                .createTime(now)
                                .updateTime(now)
                                .build();
                        seckillParticipantMapper.insert(participant);
                        
                        // 6. 异步处理订单
                        processSeckillOrderAsync(activity, userId, quantity);
                        
                        return "参与成功";
                    } else {
                        return (String) result.get(1);
                    }
                }
                
                return "参与失败";
            } else {
                return "系统繁忙，请稍后重试";
            }
        } catch (Exception e) {
            log.error("参与秒杀活动异常", e);
            return "参与失败，请重试";
        } finally {
            if (lock.isHeldByCurrentThread()) {
                lock.unlock();
            }
        }
    }
    
    /**
     * 异步处理秒杀订单
     */
    @Async
    public void processSeckillOrderAsync(SeckillActivity activity, Long userId, Integer quantity) {
        try {
            // 创建秒杀订单
            SeckillOrder order = SeckillOrder.builder()
                    .activityId(activity.getId())
                    .userId(userId)
                    .dishId(activity.getDishId())
                    .quantity(quantity)
                    .seckillPrice(activity.getSeckillPrice())
                    .totalAmount(activity.getSeckillPrice().multiply(new BigDecimal(quantity)))
                    .status(0)
                    .createTime(LocalDateTime.now())
                    .updateTime(LocalDateTime.now())
                    .build();
            
            seckillOrderMapper.insert(order);
            
            // 更新数据库库存
            updateDatabaseStock(activity.getId(), quantity);
            
            log.info("秒杀订单创建成功：orderId={}, userId={}, activityId={}", 
                    order.getId(), userId, activity.getId());
        } catch (Exception e) {
            log.error("处理秒杀订单异常", e);
        }
    }
    
    /**
     * 更新数据库库存
     */
    @Async
    public void updateDatabaseStock(Long activityId, Integer quantity) {
        try {
            // 记录库存扣减日志
            SeckillActivity activity = getById(activityId);
            SeckillStockLog stockLog = SeckillStockLog.builder()
                    .activityId(activityId)
                    .userId(0L) // 系统扣减
                    .quantity(quantity)
                    .beforeStock(activity.getStock())
                    .afterStock(activity.getStock() - quantity)
                    .status(1)
                    .createTime(LocalDateTime.now())
                    .build();
            seckillStockLogMapper.insert(stockLog);
            
            // 更新数据库库存
            seckillActivityMapper.reduceStock(activityId, quantity);
            seckillActivityMapper.increaseSoldCount(activityId, quantity);
        } catch (Exception e) {
            log.error("更新数据库库存异常", e);
        }
    }
}
```

### 2. 更新SeckillActivityService接口

**修改 `sky-server/src/main/java/com/sky/service/SeckillActivityService.java`：**

```java
package com.sky.service;

import com.github.pagehelper.Page;
import com.sky.dto.SeckillActivityDTO;
import com.sky.dto.SeckillActivityPageQueryDTO;
import com.sky.entity.SeckillActivity;
import com.sky.vo.SeckillStatisticsVO;

import java.time.LocalDateTime;
import java.util.List;

public interface SeckillActivityService {

    /**
     * 分页查询秒杀活动
     */
    Page<SeckillActivity> pageQuery(SeckillActivityPageQueryDTO seckillActivityPageQueryDTO);

    /**
     * 根据id查询秒杀活动
     */
    SeckillActivity getById(Long id);

    /**
     * 新增秒杀活动
     */
    void save(SeckillActivityDTO seckillActivityDTO);

    /**
     * 修改秒杀活动
     */
    void update(SeckillActivityDTO seckillActivityDTO);

    /**
     * 根据id删除秒杀活动
     */
    void deleteById(Long id);

    /**
     * 更新秒杀活动状态
     */
    void updateStatus(Long id, Integer status);

    /**
     * 获取秒杀活动统计信息
     */
    List<SeckillStatisticsVO> getStatistics(LocalDateTime startTime, LocalDateTime endTime);

    /**
     * 获取当前进行中的秒杀活动
     */
    List<SeckillActivity> getCurrentActivities();

    /**
     * 扣减秒杀库存
     */
    boolean reduceStock(Long id, Integer quantity);

    /**
     * 增加已售数量
     */
    void increaseSoldCount(Long id, Integer quantity);
    
    /**
     * 参与秒杀活动
     */
    String participateSeckill(Long activityId, Long userId, Integer quantity);
}
```

---

## 核心特性总结

### 1. 防超卖机制

- **Redis分布式锁**：防止同一用户重复参与
- **Lua脚本**：保证库存扣减的原子性
- **数据库锁**：防止数据库层面的并发问题

### 2. 性能优化

- **Redis缓存**：秒杀库存存储在Redis中，提高访问速度
- **异步处理**：订单创建和库存更新异步执行
- **批量操作**：减少数据库交互次数

### 3. 数据一致性

- **事务管理**：关键操作使用@Transactional保证一致性
- **补偿机制**：失败时自动回滚Redis库存
- **日志记录**：完整的操作日志便于问题排查

---

*继续阅读：[Hash咖啡后端改造指南 - 第三部分：消息队列和API接口](./Hash咖啡后端改造指南-第三部分-消息队列和API接口.md)*
