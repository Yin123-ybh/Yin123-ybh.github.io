---
title: "Hash咖啡项目后端改造指南 - 第三部分：消息队列和API接口"
date: 2025-01-14
draft: false
tags: ["Java", "Spring Boot", "RabbitMQ", "消息队列", "API接口", "异步处理", "微服务"]
categories: ["后端开发"]
description: "基于RabbitMQ的消息队列异步处理系统，实现支付和积分服务的解耦，提高系统的可扩展性和稳定性"
---

# Hash咖啡后端改造指南-第三部分-消息队列和API接口

## 目录
1. [项目概述](#1-项目概述)
2. [消息队列配置](#2-消息队列配置)
3. [消息实体类](#3-消息实体类)
4. [消息生产者服务](#4-消息生产者服务)
5. [消息消费者服务](#5-消息消费者服务)
6. [API接口实现](#6-api接口实现)
7. [Nginx配置](#7-nginx配置)
8. [部署注意事项](#8-部署注意事项)
9. [消息队列高级特性](#9-消息队列高级特性)
10. [流控和熔断](#10-流控和熔断)
11. [监控和告警](#11-监控和告警)
12. [性能优化](#12-性能优化)
13. [安全防护](#13-安全防护)
14. [测试策略](#14-测试策略)

## 概述

本部分主要介绍Hash咖啡项目中消息队列RabbitMQ的配置、消息生产者/消费者实现，以及用户端API接口的开发。通过消息队列解耦用户支付服务和积分服务，构建异步通信架构，同时实现延迟消息插件处理超时未支付订单的自动取消。

## 1. RabbitMQ配置

### 1.1 RabbitMQ配置类

**文件位置**: `sky-server/src/main/java/com/sky/config/RabbitMQConfig.java`

```java
package com.sky.config;

import org.springframework.amqp.core.*;
import org.springframework.amqp.rabbit.config.SimpleRabbitListenerContainerFactory;
import org.springframework.amqp.rabbit.connection.ConnectionFactory;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.amqp.rabbit.listener.RabbitListenerContainerFactory;
import org.springframework.amqp.support.converter.Jackson2JsonMessageConverter;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * RabbitMQ配置
 * 配置消息队列、交换机、路由等，支持异步消息处理
 */
@Configuration
public class RabbitMQConfig {
    
    // 订单相关队列
    public static final String ORDER_QUEUE = "order.queue";
    public static final String ORDER_EXCHANGE = "order.exchange";
    public static final String ORDER_ROUTING_KEY = "order.pay";
    
    // 积分相关队列
    public static final String POINTS_QUEUE = "points.queue";
    public static final String POINTS_EXCHANGE = "points.exchange";
    public static final String POINTS_ROUTING_KEY = "points.earn";
    
    // 订单超时队列
    public static final String ORDER_TIMEOUT_QUEUE = "order.timeout.queue";
    public static final String ORDER_TIMEOUT_EXCHANGE = "order.timeout.exchange";
    public static final String ORDER_TIMEOUT_ROUTING_KEY = "order.timeout";
    
    // 死信队列
    public static final String ORDER_DLX_QUEUE = "order.dlx.queue";
    public static final String ORDER_DLX_EXCHANGE = "order.dlx.exchange";
    public static final String ORDER_DLX_ROUTING_KEY = "order.dlx";
    
    /**
     * 消息转换器
     * 使用Jackson2JsonMessageConverter进行JSON序列化
     */
    @Bean
    public Jackson2JsonMessageConverter messageConverter() {
        return new Jackson2JsonMessageConverter();
    }
    
    /**
     * RabbitTemplate配置
     * 配置消息发送模板，支持消息确认和返回机制
     */
    @Bean
    public RabbitTemplate rabbitTemplate(ConnectionFactory connectionFactory) {
        RabbitTemplate template = new RabbitTemplate(connectionFactory);
        template.setMessageConverter(messageConverter());
        template.setMandatory(true);
        template.setReturnCallback((message, replyCode, replyText, exchange, routingKey) -> {
            System.out.println("消息发送失败: " + message + ", 原因: " + replyText);
        });
        return template;
    }
    
    /**
     * 消费者容器工厂配置
     * 配置消费者参数，支持手动确认和限流
     */
    @Bean
    public RabbitListenerContainerFactory<?> rabbitListenerContainerFactory(ConnectionFactory connectionFactory) {
        SimpleRabbitListenerContainerFactory factory = new SimpleRabbitListenerContainerFactory();
        factory.setConnectionFactory(connectionFactory);
        factory.setMessageConverter(messageConverter());
        factory.setAcknowledgeMode(AcknowledgeMode.MANUAL);
        factory.setConcurrentConsumers(3);
        factory.setMaxConcurrentConsumers(10);
        factory.setPrefetchCount(1);
        return factory;
    }
    
    // ========== 订单相关配置 ==========
    
    /**
     * 订单交换机
     * 使用DirectExchange，支持精确路由
     */
    @Bean
    public DirectExchange orderExchange() {
        return new DirectExchange(ORDER_EXCHANGE, true, false);
    }
    
    /**
     * 订单队列
     * 持久化队列，支持消息持久化
     */
    @Bean
    public Queue orderQueue() {
        return QueueBuilder.durable(ORDER_QUEUE).build();
    }
    
    /**
     * 订单队列绑定
     * 绑定队列到交换机，设置路由键
     */
    @Bean
    public Binding orderBinding() {
        return BindingBuilder.bind(orderQueue()).to(orderExchange()).with(ORDER_ROUTING_KEY);
    }
    
    // ========== 积分相关配置 ==========
    
    /**
     * 积分交换机
     * 使用DirectExchange，支持精确路由
     */
    @Bean
    public DirectExchange pointsExchange() {
        return new DirectExchange(POINTS_EXCHANGE, true, false);
    }
    
    /**
     * 积分队列
     * 持久化队列，支持消息持久化
     */
    @Bean
    public Queue pointsQueue() {
        return QueueBuilder.durable(POINTS_QUEUE).build();
    }
    
    /**
     * 积分队列绑定
     * 绑定队列到交换机，设置路由键
     */
    @Bean
    public Binding pointsBinding() {
        return BindingBuilder.bind(pointsQueue()).to(pointsExchange()).with(POINTS_ROUTING_KEY);
    }
    
    // ========== 订单超时相关配置 ==========
    
    /**
     * 订单超时交换机
     * 使用DirectExchange，支持精确路由
     */
    @Bean
    public DirectExchange orderTimeoutExchange() {
        return new DirectExchange(ORDER_TIMEOUT_EXCHANGE, true, false);
    }
    
    /**
     * 订单超时队列
     * 持久化队列，支持消息持久化
     */
    @Bean
    public Queue orderTimeoutQueue() {
        return QueueBuilder.durable(ORDER_TIMEOUT_QUEUE).build();
    }
    
    /**
     * 订单超时队列绑定
     * 绑定队列到交换机，设置路由键
     */
    @Bean
    public Binding orderTimeoutBinding() {
        return BindingBuilder.bind(orderTimeoutQueue()).to(orderTimeoutExchange()).with(ORDER_TIMEOUT_ROUTING_KEY);
    }
    
    // ========== 死信队列配置 ==========
    
    /**
     * 死信交换机
     * 使用DirectExchange，支持精确路由
     */
    @Bean
    public DirectExchange orderDlxExchange() {
        return new DirectExchange(ORDER_DLX_EXCHANGE, true, false);
    }
    
    /**
     * 死信队列
     * 持久化队列，支持消息持久化
     */
    @Bean
    public Queue orderDlxQueue() {
        return QueueBuilder.durable(ORDER_DLX_QUEUE).build();
    }
    
    /**
     * 死信队列绑定
     * 绑定队列到交换机，设置路由键
     */
    @Bean
    public Binding orderDlxBinding() {
        return BindingBuilder.bind(orderDlxQueue()).to(orderDlxExchange()).with(ORDER_DLX_ROUTING_KEY);
    }
}
```

**配置特点**:
1. **消息持久化**: 确保消息不丢失
2. **手动确认**: 提高消息处理可靠性
3. **限流配置**: 防止消费者过载
4. **死信队列**: 处理失败消息

### 1.2 配置文件更新

**文件位置**: `sky-server/src/main/resources/application.yml`

```yaml
# 在现有配置基础上添加以下配置

spring:
  # RabbitMQ配置
  rabbitmq:
    host: ${sky.rabbitmq.host:localhost}
    port: ${sky.rabbitmq.port:5672}
    username: ${sky.rabbitmq.username:guest}
    password: ${sky.rabbitmq.password:guest}
    virtual-host: ${sky.rabbitmq.virtual-host:/}
    connection-timeout: 15000
    publisher-confirm-type: correlated
    publisher-returns: true
    listener:
      simple:
        acknowledge-mode: manual
        retry:
          enabled: true
          max-attempts: 3
          initial-interval: 1000
          max-interval: 10000
          multiplier: 2
        concurrency: 3
        max-concurrency: 10
        prefetch: 1

  # Redis配置
  redis:
    host: ${sky.redis.host}
    port: ${sky.redis.port}
    database: ${sky.redis.database}
    password: ${sky.redis.password}
    timeout: 5000ms
    lettuce:
      pool:
        max-active: 8
        max-wait: -1ms
        max-idle: 8
        min-idle: 0

# 日志配置
logging:
  level:
    com:
      sky:
        mapper: debug
        service: info
        controller: info
    org.springframework.amqp: debug
  pattern:
    console: "%clr(%d{yyyy-MM-dd HH:mm:ss}){faint} %clr([%thread]){faint} %clr(%-5level) %clr(%logger{36}){cyan} %clr(-){faint} %msg%n"
    file: "%d{yyyy-MM-dd HH:mm:ss} [%thread] %-5level %logger{36} - %msg%n"
  file:
    name: logs/sky-server.log
    max-size: 100MB
    max-history: 30

# 自定义配置
sky:
  redis:
    seckill:
      prefix: "seckill:"
```

**配置说明**:
- **连接配置**: 支持环境变量配置
- **确认机制**: 支持消息确认和返回
- **重试机制**: 支持消息重试
- **限流配置**: 支持消费者限流

## 2. 消息生产者服务

### 2.1 消息生产者接口

**文件位置**: `sky-server/src/main/java/com/sky/service/MessageProducerService.java`

```java
package com.sky.service;

import com.sky.entity.message.OrderPayMessage;
import com.sky.entity.message.OrderTimeoutMessage;
import com.sky.entity.message.PointsEarnMessage;

/**
 * 消息生产者服务接口
 * 定义消息发送的接口规范
 */
public interface MessageProducerService {
    
    /**
     * 发送订单支付消息
     * @param message 订单支付消息
     */
    void sendOrderPayMessage(OrderPayMessage message);
    
    /**
     * 发送积分获得消息
     * @param message 积分获得消息
     */
    void sendPointsEarnMessage(PointsEarnMessage message);
    
    /**
     * 发送订单超时消息
     * @param message 订单超时消息
     */
    void sendOrderTimeoutMessage(OrderTimeoutMessage message);
}
```

### 2.2 消息生产者实现

**文件位置**: `sky-server/src/main/java/com/sky/service/impl/MessageProducerServiceImpl.java`

```java
package com.sky.service.impl;

import com.sky.entity.message.OrderPayMessage;
import com.sky.entity.message.OrderTimeoutMessage;
import com.sky.entity.message.PointsEarnMessage;
import com.sky.service.MessageProducerService;
import lombok.extern.slf4j.Slf4j;
import org.springframework.amqp.core.MessageDeliveryMode;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;

/**
 * 消息生产者服务实现类
 * 实现消息发送的具体逻辑
 */
@Service
@Slf4j
public class MessageProducerServiceImpl implements MessageProducerService {
    
    @Autowired
    private RabbitTemplate rabbitTemplate;
    
    /**
     * 发送订单支付消息
     * 用于异步处理订单支付后的业务逻辑
     */
    @Override
    public void sendOrderPayMessage(OrderPayMessage message) {
        try {
            rabbitTemplate.convertAndSend(
                "order.exchange",
                "order.pay",
                message,
                msg -> {
                    msg.getMessageProperties().setDeliveryMode(MessageDeliveryMode.PERSISTENT);
                    return msg;
                }
            );
            log.info("订单支付消息发送成功: {}", message);
        } catch (Exception e) {
            log.error("订单支付消息发送失败: {}", message, e);
            throw new RuntimeException("消息发送失败", e);
        }
    }
    
    /**
     * 发送积分获得消息
     * 用于异步处理用户积分增加
     */
    @Override
    public void sendPointsEarnMessage(PointsEarnMessage message) {
        try {
            rabbitTemplate.convertAndSend(
                "points.exchange",
                "points.earn",
                message,
                msg -> {
                    msg.getMessageProperties().setDeliveryMode(MessageDeliveryMode.PERSISTENT);
                    return msg;
                }
            );
            log.info("积分获得消息发送成功: {}", message);
        } catch (Exception e) {
            log.error("积分获得消息发送失败: {}", message, e);
            throw new RuntimeException("消息发送失败", e);
        }
    }
    
    /**
     * 发送订单超时消息
     * 用于异步处理订单超时取消
     */
    @Override
    public void sendOrderTimeoutMessage(OrderTimeoutMessage message) {
        try {
            rabbitTemplate.convertAndSend(
                "order.timeout.exchange",
                "order.timeout",
                message,
                msg -> {
                    msg.getMessageProperties().setDeliveryMode(MessageDeliveryMode.PERSISTENT);
                    return msg;
                }
            );
            log.info("订单超时消息发送成功: {}", message);
        } catch (Exception e) {
            log.error("订单超时消息发送失败: {}", message, e);
            throw new RuntimeException("消息发送失败", e);
        }
    }
}
```

**设计特点**:
1. **消息持久化**: 确保消息不丢失
2. **异常处理**: 完善的异常处理机制
3. **日志记录**: 详细的操作日志
4. **异步处理**: 提高系统响应速度

## 3. 消息消费者服务

### 3.1 消息消费者接口

**文件位置**: `sky-server/src/main/java/com/sky/service/MessageConsumerService.java`

```java
package com.sky.service;

import com.sky.entity.message.OrderPayMessage;
import com.sky.entity.message.OrderTimeoutMessage;
import com.sky.entity.message.PointsEarnMessage;

/**
 * 消息消费者服务接口
 * 定义消息消费的接口规范
 */
public interface MessageConsumerService {
    
    /**
     * 处理订单支付消息
     * @param message 订单支付消息
     */
    void handleOrderPayMessage(OrderPayMessage message);
    
    /**
     * 处理积分获得消息
     * @param message 积分获得消息
     */
    void handlePointsEarnMessage(PointsEarnMessage message);
    
    /**
     * 处理订单超时消息
     * @param message 订单超时消息
     */
    void handleOrderTimeoutMessage(OrderTimeoutMessage message);
}
```

### 3.2 消息消费者实现

**文件位置**: `sky-server/src/main/java/com/sky/service/impl/MessageConsumerServiceImpl.java`

```java
package com.sky.service.impl;

import com.rabbitmq.client.Channel;
import com.sky.entity.message.OrderPayMessage;
import com.sky.entity.message.OrderTimeoutMessage;
import com.sky.entity.message.PointsEarnMessage;
import com.sky.service.MessageConsumerService;
import com.sky.service.MessageProducerService;
import com.sky.service.OrderService;
import com.sky.service.UserService;
import lombok.extern.slf4j.Slf4j;
import org.springframework.amqp.rabbit.annotation.RabbitListener;
import org.springframework.amqp.support.AmqpHeaders;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.messaging.handler.annotation.Header;
import org.springframework.stereotype.Service;

import java.io.IOException;

/**
 * 消息消费者服务实现类
 * 实现消息消费的具体逻辑
 */
@Service
@Slf4j
public class MessageConsumerServiceImpl implements MessageConsumerService {
    
    @Autowired
    private OrderService orderService;
    
    @Autowired
    private UserService userService;
    
    @Autowired
    private MessageProducerService messageProducerService;
    
    /**
     * 处理订单支付消息
     * 异步处理订单支付后的业务逻辑
     */
    @RabbitListener(queues = "order.queue")
    public void handleOrderPayMessage(OrderPayMessage message, Channel channel, 
                                    @Header(AmqpHeaders.DELIVERY_TAG) long deliveryTag) {
        try {
            log.info("收到订单支付消息: {}", message);
            
            // 处理订单支付
            orderService.processOrderPayment(message.getOrderId(), message.getAmount());
            
            // 发送积分获得消息
            PointsEarnMessage pointsMessage = PointsEarnMessage.builder()
                    .userId(message.getUserId())
                    .orderId(message.getOrderId())
                    .points(calculatePoints(message.getAmount()))
                    .earnTime(message.getPayTime())
                    .build();
            
            messageProducerService.sendPointsEarnMessage(pointsMessage);
            
            // 手动确认消息
            channel.basicAck(deliveryTag, false);
            log.info("订单支付消息处理成功: {}", message);
            
        } catch (Exception e) {
            log.error("订单支付消息处理失败: {}", message, e);
            try {
                // 拒绝消息，不重新入队
                channel.basicNack(deliveryTag, false, false);
            } catch (IOException ioException) {
                log.error("消息拒绝失败", ioException);
            }
        }
    }
    
    /**
     * 处理积分获得消息
     * 异步处理用户积分增加
     */
    @RabbitListener(queues = "points.queue")
    public void handlePointsEarnMessage(PointsEarnMessage message, Channel channel, 
                                      @Header(AmqpHeaders.DELIVERY_TAG) long deliveryTag) {
        try {
            log.info("收到积分获得消息: {}", message);
            
            // 添加用户积分
            userService.addUserPoints(message.getUserId(), message.getPoints(), message.getOrderId());
            
            // 手动确认消息
            channel.basicAck(deliveryTag, false);
            log.info("积分获得消息处理成功: {}", message);
            
        } catch (Exception e) {
            log.error("积分获得消息处理失败: {}", message, e);
            try {
                // 拒绝消息，不重新入队
                channel.basicNack(deliveryTag, false, false);
            } catch (IOException ioException) {
                log.error("消息拒绝失败", ioException);
            }
        }
    }
    
    /**
     * 处理订单超时消息
     * 异步处理订单超时取消
     */
    @RabbitListener(queues = "order.timeout.queue")
    public void handleOrderTimeoutMessage(OrderTimeoutMessage message, Channel channel, 
                                        @Header(AmqpHeaders.DELIVERY_TAG) long deliveryTag) {
        try {
            log.info("收到订单超时消息: {}", message);
            
            // 取消超时订单
            orderService.cancelTimeoutOrder(message.getOrderId());
            
            // 手动确认消息
            channel.basicAck(deliveryTag, false);
            log.info("订单超时消息处理成功: {}", message);
            
        } catch (Exception e) {
            log.error("订单超时消息处理失败: {}", message, e);
            try {
                // 拒绝消息，不重新入队
                channel.basicNack(deliveryTag, false, false);
            } catch (IOException ioException) {
                log.error("消息拒绝失败", ioException);
            }
        }
    }
    
    /**
     * 计算积分
     * 根据订单金额计算用户获得的积分
     */
    private Integer calculatePoints(java.math.BigDecimal amount) {
        // 每消费1元获得1积分
        return amount.intValue();
    }
}
```

**设计特点**:
1. **手动确认**: 确保消息处理成功后才确认
2. **异常处理**: 完善的异常处理机制
3. **业务解耦**: 通过消息队列解耦业务逻辑
4. **异步处理**: 提高系统响应速度

## 4. 用户端API接口

### 4.1 用户端秒杀活动控制器

**文件位置**: `sky-server/src/main/java/com/sky/controller/user/UserSeckillActivityController.java`

```java
package com.sky.controller.user;

import com.sky.entity.SeckillActivity;
import com.sky.result.Result;
import com.sky.service.SeckillActivityService;
import io.swagger.annotations.Api;
import io.swagger.annotations.ApiOperation;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.web.bind.annotation.*;

import java.util.List;

/**
 * 用户端秒杀活动控制器
 * 提供秒杀活动相关的用户端接口
 */
@RestController
@RequestMapping("/user/seckill/activity")
@Api(tags = "用户端秒杀活动")
@Slf4j
public class UserSeckillActivityController {

    @Autowired
    private SeckillActivityService seckillActivityService;

    @GetMapping("/current")
    @ApiOperation("获取当前进行中的秒杀活动")
    public Result<List<SeckillActivity>> getCurrentActivities() {
        log.info("获取当前进行中的秒杀活动");
        List<SeckillActivity> activities = seckillActivityService.getCurrentActivities();
        return Result.success(activities);
    }

    @GetMapping("/{id}")
    @ApiOperation("根据id查询秒杀活动详情")
    public Result<SeckillActivity> getById(@PathVariable Long id) {
        log.info("根据id查询秒杀活动详情：{}", id);
        SeckillActivity seckillActivity = seckillActivityService.getById(id);
        return Result.success(seckillActivity);
    }

    @PostMapping("/participate/{id}")
    @ApiOperation("参与秒杀活动")
    public Result<String> participateSeckill(@PathVariable Long id, 
                                           @RequestParam Integer quantity,
                                           @RequestHeader("userId") Long userId) {
        log.info("用户参与秒杀活动：id={}, quantity={}, userId={}", id, quantity, userId);
        String result = seckillActivityService.participateSeckill(id, userId, quantity);
        return Result.success(result);
    }
}
```

**接口说明**:
1. **获取活动列表**: 获取当前可参与的秒杀活动
2. **活动详情**: 获取指定活动的详细信息
3. **参与秒杀**: 用户参与秒杀活动

### 4.2 用户端优惠券控制器

**文件位置**: `sky-server/src/main/java/com/sky/controller/user/UserCouponController.java`

```java
package com.sky.controller.user;

import com.sky.entity.Coupon;
import com.sky.entity.CouponTemplate;
import com.sky.result.Result;
import com.sky.service.CouponService;
import com.sky.service.CouponTemplateService;
import io.swagger.annotations.Api;
import io.swagger.annotations.ApiOperation;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.web.bind.annotation.*;

import java.math.BigDecimal;
import java.util.List;

/**
 * 用户端优惠券控制器
 * 提供优惠券相关的用户端接口
 */
@RestController
@RequestMapping("/user/coupon")
@Api(tags = "用户端优惠券")
@Slf4j
public class UserCouponController {

    @Autowired
    private CouponTemplateService couponTemplateService;
    
    @Autowired
    private CouponService couponService;

    @GetMapping("/templates/available")
    @ApiOperation("获取可领取的优惠券模板")
    public Result<List<CouponTemplate>> getAvailableTemplates() {
        log.info("获取可领取的优惠券模板");
        List<CouponTemplate> templates = couponTemplateService.getAvailableTemplates();
        return Result.success(templates);
    }

    @PostMapping("/claim")
    @ApiOperation("领取优惠券")
    public Result<String> claimCoupon(@RequestParam Long templateId,
                                    @RequestHeader("userId") Long userId) {
        log.info("用户领取优惠券：templateId={}, userId={}", templateId, userId);
        String result = couponService.claimCoupon(templateId, userId);
        return Result.success(result);
    }

    @GetMapping("/my")
    @ApiOperation("获取我的优惠券")
    public Result<List<Coupon>> getMyCoupons(@RequestHeader("userId") Long userId) {
        log.info("获取用户优惠券：userId={}", userId);
        List<Coupon> coupons = couponService.getUserAvailableCoupons(userId);
        return Result.success(coupons);
    }

    @PostMapping("/check")
    @ApiOperation("检查优惠券是否可用")
    public Result<String> checkCouponAvailable(@RequestParam Long couponId,
                                             @RequestParam BigDecimal orderAmount,
                                             @RequestHeader("userId") Long userId) {
        log.info("检查优惠券是否可用：couponId={}, orderAmount={}, userId={}", couponId, orderAmount, userId);
        String result = couponService.checkCouponAvailable(couponId, userId, orderAmount);
        return Result.success(result);
    }
}
```

**接口说明**:
1. **获取优惠券模板**: 获取可领取的优惠券模板
2. **领取优惠券**: 用户领取优惠券
3. **我的优惠券**: 获取用户的优惠券列表
4. **检查优惠券**: 检查优惠券是否可用

### 4.3 健康检查控制器

**文件位置**: `sky-server/src/main/java/com/sky/controller/HealthController.java`

```java
package com.sky.controller;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.data.redis.core.RedisTemplate;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.HashMap;
import java.util.Map;

/**
 * 健康检查控制器
 * 提供系统健康状态检查接口
 */
@RestController
@RequestMapping("/health")
public class HealthController {
    
    @Autowired
    private RedisTemplate<String, Object> redisTemplate;
    
    @GetMapping("/check")
    public Map<String, Object> healthCheck() {
        Map<String, Object> result = new HashMap<>();
        
        // 检查Redis连接
        try {
            redisTemplate.opsForValue().get("health:check");
            result.put("redis", "UP");
        } catch (Exception e) {
            result.put("redis", "DOWN");
        }
        
        // 检查应用状态
        result.put("application", "UP");
        result.put("timestamp", System.currentTimeMillis());
        
        return result;
    }
}
```

**功能说明**:
1. **Redis检查**: 检查Redis连接状态
2. **应用状态**: 检查应用运行状态
3. **时间戳**: 返回检查时间

## 5. Nginx配置更新

**文件位置**: `nginx-conf/New file.txt`

```nginx
# 在现有配置基础上添加以下配置

    # 秒杀活动相关接口
    location /seckill/ {
        proxy_pass   http://localhost:8084/user/seckill/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    
    # 优惠券相关接口
    location /coupon/ {
        proxy_pass   http://localhost:8084/user/coupon/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    
    # 健康检查接口
    location /health/ {
        proxy_pass   http://localhost:8084/health/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
```

**配置说明**:
- **反向代理**: 将请求转发到后端服务
- **请求头设置**: 保持原始请求信息
- **负载均衡**: 支持多实例部署

## 6. 关键特性

### 6.1 消息队列解耦
- 支付服务和积分服务完全解耦
- 异步处理提高系统性能
- 消息持久化保证可靠性

### 6.2 削峰填谷
- 消费者容器工厂限流配置
- 手动ACK机制
- 消息重试机制

### 6.3 延迟消息处理
- 订单超时自动取消
- 死信队列处理失败消息
- 消息TTL设置

### 6.4 服务监控
- 健康检查接口
- 日志彩色输出
- 性能监控

## 7. 测试建议

### 7.1 消息队列测试
1. **消息发送测试**: 测试各种消息的发送
2. **消息消费测试**: 测试消息的消费处理
3. **异常处理测试**: 测试消息处理异常情况
4. **性能测试**: 测试高并发消息处理

### 7.2 API接口测试
1. **秒杀接口测试**: 测试秒杀活动的参与
2. **优惠券接口测试**: 测试优惠券的领取和使用
3. **健康检查测试**: 测试系统健康状态
4. **并发测试**: 测试高并发场景

## 8. 部署注意事项

1. **RabbitMQ配置**: 确保RabbitMQ服务正常运行
2. **Redis配置**: 确保Redis连接配置正确
3. **日志配置**: 确保日志文件路径存在
4. **Nginx配置**: 确保反向代理配置正确

## 9. 消息队列高级特性

### 9.1 消息可靠性保证

#### 9.1.1 生产者确认机制

**确认模式配置**:
```yaml
spring:
  rabbitmq:
    publisher-confirm-type: correlated
    publisher-returns: true
    template:
      mandatory: true
```

**确认回调处理**:
```java
@Configuration
public class RabbitMQConfirmConfig {
    
    @Bean
    public RabbitTemplate rabbitTemplate(ConnectionFactory connectionFactory) {
        RabbitTemplate template = new RabbitTemplate(connectionFactory);
        
        // 设置确认回调
        template.setConfirmCallback((correlationData, ack, cause) -> {
            if (ack) {
                log.info("消息发送成功: {}", correlationData.getId());
            } else {
                log.error("消息发送失败: {}, 原因: {}", correlationData.getId(), cause);
            }
        });
        
        // 设置返回回调
        template.setReturnsCallback(returned -> {
            log.error("消息路由失败: {}, 回复码: {}, 回复文本: {}", 
                returned.getMessage(), returned.getReplyCode(), returned.getReplyText());
        });
        
        return template;
    }
}
```

#### 9.1.2 消费者确认机制

**手动确认配置**:
```yaml
spring:
  rabbitmq:
    listener:
      simple:
        acknowledge-mode: manual
        retry:
          enabled: true
          max-attempts: 3
          initial-interval: 1000
```

**消息处理示例**:
```java
@RabbitListener(queues = "order.pay.queue")
public void handleOrderPay(OrderPayMessage message, Channel channel, 
                          @Header(AmqpHeaders.DELIVERY_TAG) long deliveryTag) {
    try {
        // 处理业务逻辑
        processOrderPayment(message);
        
        // 手动确认消息
        channel.basicAck(deliveryTag, false);
        log.info("订单支付消息处理成功: {}", message.getOrderId());
    } catch (Exception e) {
        try {
            // 拒绝消息并重新入队
            channel.basicNack(deliveryTag, false, true);
            log.error("订单支付消息处理失败: {}", message.getOrderId(), e);
        } catch (IOException ioException) {
            log.error("消息确认失败", ioException);
        }
    }
}
```

### 9.2 消息持久化

#### 9.2.1 队列持久化

**队列配置**:
```java
@Bean
public Queue orderPayQueue() {
    return QueueBuilder.durable("order.pay.queue")
        .withArgument("x-message-ttl", 300000) // 消息TTL 5分钟
        .withArgument("x-max-length", 10000)  // 最大长度
        .build();
}
```

**交换机持久化**:
```java
@Bean
public TopicExchange orderExchange() {
    return ExchangeBuilder.topicExchange("order.exchange")
        .durable(true)
        .build();
}
```

#### 9.2.2 消息持久化

**消息属性设置**:
```java
public void sendOrderPayMessage(OrderPayMessage message) {
    MessageProperties properties = new MessageProperties();
    properties.setDeliveryMode(MessageDeliveryMode.PERSISTENT);
    properties.setPriority(5);
    properties.setExpiration("300000"); // 5分钟过期
    
    Message msg = new Message(JSON.toJSONBytes(message), properties);
    
    rabbitTemplate.convertAndSend("order.exchange", "order.pay", msg);
}
```

### 9.3 死信队列

#### 9.3.1 死信队列配置

**死信交换机配置**:
```java
@Bean
public TopicExchange deadLetterExchange() {
    return ExchangeBuilder.topicExchange("dead.letter.exchange")
        .durable(true)
        .build();
}

@Bean
public Queue deadLetterQueue() {
    return QueueBuilder.durable("dead.letter.queue").build();
}

@Bean
public Binding deadLetterBinding() {
    return BindingBuilder.bind(deadLetterQueue())
        .to(deadLetterExchange())
        .with("dead.letter.#");
}
```

**业务队列配置**:
```java
@Bean
public Queue orderPayQueue() {
    return QueueBuilder.durable("order.pay.queue")
        .withArgument("x-dead-letter-exchange", "dead.letter.exchange")
        .withArgument("x-dead-letter-routing-key", "dead.letter.order.pay")
        .withArgument("x-message-ttl", 300000)
        .build();
}
```

#### 9.3.2 死信处理

**死信消息处理**:
```java
@RabbitListener(queues = "dead.letter.queue")
public void handleDeadLetter(String message, @Header("x-dead-letter-reason") String reason) {
    log.warn("收到死信消息: {}, 原因: {}", message, reason);
    
    // 根据死信原因进行不同处理
    if ("expired".equals(reason)) {
        // 处理过期消息
        handleExpiredMessage(message);
    } else if ("rejected".equals(reason)) {
        // 处理被拒绝的消息
        handleRejectedMessage(message);
    }
}
```

### 9.4 消息幂等性

#### 9.4.1 幂等性保证

**消息去重**:
```java
@Service
public class MessageIdempotencyService {
    
    @Autowired
    private RedisTemplate<String, String> redisTemplate;
    
    private static final String MESSAGE_PROCESSED_KEY = "message:processed:";
    private static final int EXPIRE_TIME = 3600; // 1小时
    
    public boolean isMessageProcessed(String messageId) {
        String key = MESSAGE_PROCESSED_KEY + messageId;
        return redisTemplate.hasKey(key);
    }
    
    public void markMessageProcessed(String messageId) {
        String key = MESSAGE_PROCESSED_KEY + messageId;
        redisTemplate.opsForValue().set(key, "1", EXPIRE_TIME, TimeUnit.SECONDS);
    }
}
```

**幂等性处理**:
```java
@RabbitListener(queues = "order.pay.queue")
public void handleOrderPay(OrderPayMessage message, Channel channel, 
                          @Header(AmqpHeaders.DELIVERY_TAG) long deliveryTag) {
    String messageId = message.getMessageId();
    
    // 检查消息是否已处理
    if (messageIdempotencyService.isMessageProcessed(messageId)) {
        log.info("消息已处理，跳过: {}", messageId);
        channel.basicAck(deliveryTag, false);
        return;
    }
    
    try {
        // 处理业务逻辑
        processOrderPayment(message);
        
        // 标记消息已处理
        messageIdempotencyService.markMessageProcessed(messageId);
        
        // 确认消息
        channel.basicAck(deliveryTag, false);
    } catch (Exception e) {
        log.error("消息处理失败: {}", messageId, e);
        // 拒绝消息
        channel.basicNack(deliveryTag, false, false);
    }
}
```

## 10. 流控和熔断

### 10.1 Sentinel流控

#### 10.1.1 流控规则配置

**流控规则定义**:
```java
@Component
public class SentinelFlowControlConfig {
    
    @PostConstruct
    public void initFlowRules() {
        List<FlowRule> rules = new ArrayList<>();
        
        // 秒杀接口流控
        FlowRule seckillRule = new FlowRule();
        seckillRule.setResource("seckill:participate");
        seckillRule.setGrade(RuleConstant.FLOW_GRADE_QPS);
        seckillRule.setCount(100); // 每秒100个请求
        seckillRule.setControlBehavior(RuleConstant.CONTROL_BEHAVIOR_RATE_LIMITER);
        rules.add(seckillRule);
        
        // 优惠券接口流控
        FlowRule couponRule = new FlowRule();
        couponRule.setResource("coupon:claim");
        couponRule.setGrade(RuleConstant.FLOW_GRADE_QPS);
        couponRule.setCount(50); // 每秒50个请求
        couponRule.setControlBehavior(RuleConstant.CONTROL_BEHAVIOR_RATE_LIMITER);
        rules.add(couponRule);
        
        FlowRuleManager.loadRules(rules);
    }
}
```

#### 10.1.2 流控处理

**流控异常处理**:
```java
@RestController
public class SeckillController {
    
    @SentinelResource(value = "seckill:participate", 
                     blockHandler = "handleSeckillBlock",
                     fallback = "handleSeckillFallback")
    @PostMapping("/seckill/participate")
    public Result participateSeckill(@RequestBody SeckillParticipateDTO dto) {
        return seckillService.participateSeckill(dto);
    }
    
    public Result handleSeckillBlock(SeckillParticipateDTO dto, BlockException ex) {
        log.warn("秒杀接口被流控: {}", ex.getMessage());
        return Result.error("系统繁忙，请稍后重试");
    }
    
    public Result handleSeckillFallback(SeckillParticipateDTO dto, Throwable ex) {
        log.error("秒杀接口异常: {}", ex.getMessage());
        return Result.error("系统异常，请稍后重试");
    }
}
```

### 10.2 熔断降级

#### 10.2.1 熔断规则配置

**熔断规则定义**:
```java
@Component
public class SentinelCircuitBreakerConfig {
    
    @PostConstruct
    public void initCircuitBreakerRules() {
        List<CircuitBreakerRule> rules = new ArrayList<>();
        
        // 数据库熔断规则
        CircuitBreakerRule dbRule = new CircuitBreakerRule();
        dbRule.setResource("database:query");
        dbRule.setGrade(RuleConstant.DEGRADE_GRADE_RT);
        dbRule.setCount(100); // 平均响应时间100ms
        dbRule.setTimeWindow(10); // 熔断时长10秒
        dbRule.setMinRequestAmount(5); // 最小请求数
        dbRule.setStatIntervalMs(1000); // 统计时长1秒
        rules.add(dbRule);
        
        // Redis熔断规则
        CircuitBreakerRule redisRule = new CircuitBreakerRule();
        redisRule.setResource("redis:operation");
        redisRule.setGrade(RuleConstant.DEGRADE_GRADE_EXCEPTION_RATIO);
        redisRule.setCount(0.5); // 异常比例50%
        redisRule.setTimeWindow(10);
        redisRule.setMinRequestAmount(5);
        redisRule.setStatIntervalMs(1000);
        rules.add(redisRule);
        
        CircuitBreakerRuleManager.loadRules(rules);
    }
}
```

#### 10.2.2 熔断处理

**熔断降级处理**:
```java
@Service
public class SeckillService {
    
    @SentinelResource(value = "database:query",
                     fallback = "fallbackQueryActivity")
    public SeckillActivity queryActivity(Long activityId) {
        return seckillActivityMapper.selectById(activityId);
    }
    
    public SeckillActivity fallbackQueryActivity(Long activityId, Throwable ex) {
        log.error("数据库查询熔断: {}", ex.getMessage());
        // 返回缓存数据或默认值
        return getCachedActivity(activityId);
    }
    
    @SentinelResource(value = "redis:operation",
                     fallback = "fallbackRedisOperation")
    public void updateStock(Long activityId, Integer quantity) {
        redisTemplate.opsForValue().decrement("seckill:stock:" + activityId, quantity);
    }
    
    public void fallbackRedisOperation(Long activityId, Integer quantity, Throwable ex) {
        log.error("Redis操作熔断: {}", ex.getMessage());
        // 降级处理：直接更新数据库
        updateStockInDatabase(activityId, quantity);
    }
}
```

## 11. 监控和告警

### 11.1 应用监控

#### 11.1.1 指标收集

**自定义指标**:
```java
@Component
public class BusinessMetrics {
    
    private final MeterRegistry meterRegistry;
    private final Counter seckillSuccessCounter;
    private final Counter seckillFailCounter;
    private final Timer seckillTimer;
    
    public BusinessMetrics(MeterRegistry meterRegistry) {
        this.meterRegistry = meterRegistry;
        this.seckillSuccessCounter = Counter.builder("seckill.success")
            .description("秒杀成功次数")
            .register(meterRegistry);
        this.seckillFailCounter = Counter.builder("seckill.fail")
            .description("秒杀失败次数")
            .register(meterRegistry);
        this.seckillTimer = Timer.builder("seckill.duration")
            .description("秒杀处理时间")
            .register(meterRegistry);
    }
    
    public void recordSeckillSuccess() {
        seckillSuccessCounter.increment();
    }
    
    public void recordSeckillFail() {
        seckillFailCounter.increment();
    }
    
    public void recordSeckillDuration(Duration duration) {
        seckillTimer.record(duration);
    }
}
```

#### 11.1.2 健康检查

**健康检查配置**:
```java
@Component
public class CustomHealthIndicator implements HealthIndicator {
    
    @Autowired
    private RedisTemplate<String, String> redisTemplate;
    
    @Autowired
    private DataSource dataSource;
    
    @Override
    public Health health() {
        Health.Builder builder = new Health.Builder();
        
        // 检查Redis连接
        try {
            redisTemplate.opsForValue().get("health:check");
            builder.withDetail("redis", "UP");
        } catch (Exception e) {
            builder.down().withDetail("redis", "DOWN: " + e.getMessage());
        }
        
        // 检查数据库连接
        try {
            dataSource.getConnection().close();
            builder.withDetail("database", "UP");
        } catch (Exception e) {
            builder.down().withDetail("database", "DOWN: " + e.getMessage());
        }
        
        return builder.build();
    }
}
```

### 11.2 业务监控

#### 11.2.1 业务指标监控

**业务指标收集**:
```java
@Service
public class BusinessMonitorService {
    
    @Autowired
    private BusinessMetrics businessMetrics;
    
    @EventListener
    public void handleSeckillSuccess(SeckillSuccessEvent event) {
        businessMetrics.recordSeckillSuccess();
        log.info("秒杀成功: 活动ID={}, 用户ID={}", 
            event.getActivityId(), event.getUserId());
    }
    
    @EventListener
    public void handleSeckillFail(SeckillFailEvent event) {
        businessMetrics.recordSeckillFail();
        log.warn("秒杀失败: 活动ID={}, 用户ID={}, 原因={}", 
            event.getActivityId(), event.getUserId(), event.getReason());
    }
    
    @EventListener
    public void handleCouponClaim(CouponClaimEvent event) {
        log.info("优惠券领取: 模板ID={}, 用户ID={}", 
            event.getTemplateId(), event.getUserId());
    }
}
```

#### 11.2.2 告警配置

**告警规则配置**:
```yaml
management:
  endpoints:
    web:
      exposure:
        include: health,metrics,prometheus
  metrics:
    export:
      prometheus:
        enabled: true
    tags:
      application: sky-server
```

**告警规则**:
```yaml
groups:
- name: sky-server-alerts
  rules:
  - alert: HighErrorRate
    expr: rate(http_server_requests_seconds_count{status=~"5.."}[5m]) > 0.1
    for: 2m
    labels:
      severity: warning
    annotations:
      summary: "高错误率告警"
      description: "错误率超过10%"
  
  - alert: HighResponseTime
    expr: histogram_quantile(0.95, rate(http_server_requests_seconds_bucket[5m])) > 1
    for: 2m
    labels:
      severity: warning
    annotations:
      summary: "高响应时间告警"
      description: "95%响应时间超过1秒"
```

## 12. 性能优化

### 12.1 缓存优化

#### 12.1.1 多级缓存

**本地缓存配置**:
```java
@Configuration
@EnableCaching
public class CacheConfig {
    
    @Bean
    public CacheManager cacheManager() {
        CaffeineCacheManager cacheManager = new CaffeineCacheManager();
        cacheManager.setCaffeine(Caffeine.newBuilder()
            .maximumSize(1000)
            .expireAfterWrite(10, TimeUnit.MINUTES)
            .recordStats());
        return cacheManager;
    }
}
```

**多级缓存实现**:
```java
@Service
public class SeckillActivityService {
    
    @Cacheable(value = "seckill:activity", key = "#activityId")
    public SeckillActivity getActivity(Long activityId) {
        // 先从本地缓存获取
        SeckillActivity activity = localCache.get(activityId);
        if (activity != null) {
            return activity;
        }
        
        // 从Redis获取
        activity = redisTemplate.opsForValue().get("seckill:activity:" + activityId);
        if (activity != null) {
            localCache.put(activityId, activity);
            return activity;
        }
        
        // 从数据库获取
        activity = seckillActivityMapper.selectById(activityId);
        if (activity != null) {
            redisTemplate.opsForValue().set("seckill:activity:" + activityId, activity, 10, TimeUnit.MINUTES);
            localCache.put(activityId, activity);
        }
        
        return activity;
    }
}
```

#### 12.1.2 缓存预热

**缓存预热服务**:
```java
@Service
public class CacheWarmupService {
    
    @Autowired
    private SeckillActivityService seckillActivityService;
    
    @Autowired
    private RedisTemplate<String, Object> redisTemplate;
    
    @PostConstruct
    public void warmupCache() {
        // 预热秒杀活动缓存
        List<SeckillActivity> activities = seckillActivityService.getActiveActivities();
        for (SeckillActivity activity : activities) {
            String key = "seckill:activity:" + activity.getId();
            redisTemplate.opsForValue().set(key, activity, 10, TimeUnit.MINUTES);
        }
        
        // 预热库存缓存
        for (SeckillActivity activity : activities) {
            String stockKey = "seckill:stock:" + activity.getId();
            redisTemplate.opsForValue().set(stockKey, activity.getStock());
        }
    }
}
```

### 12.2 数据库优化

#### 12.2.1 读写分离

**数据源配置**:
```yaml
spring:
  datasource:
    master:
      url: jdbc:mysql://localhost:3306/sky?useUnicode=true&characterEncoding=utf8&serverTimezone=GMT%2B8
      username: root
      password: root
      driver-class-name: com.mysql.cj.jdbc.Driver
    slave:
      url: jdbc:mysql://localhost:3307/sky?useUnicode=true&characterEncoding=utf8&serverTimezone=GMT%2B8
      username: root
      password: root
      driver-class-name: com.mysql.cj.jdbc.Driver
```

**读写分离配置**:
```java
@Configuration
public class DataSourceConfig {
    
    @Bean
    @Primary
    public DataSource masterDataSource() {
        return DataSourceBuilder.create()
            .url("jdbc:mysql://localhost:3306/sky")
            .username("root")
            .password("root")
            .driverClassName("com.mysql.cj.jdbc.Driver")
            .build();
    }
    
    @Bean
    public DataSource slaveDataSource() {
        return DataSourceBuilder.create()
            .url("jdbc:mysql://localhost:3307/sky")
            .username("root")
            .password("root")
            .driverClassName("com.mysql.cj.jdbc.Driver")
            .build();
    }
    
    @Bean
    public DataSource routingDataSource() {
        DynamicRoutingDataSource routingDataSource = new DynamicRoutingDataSource();
        Map<Object, Object> dataSourceMap = new HashMap<>();
        dataSourceMap.put("master", masterDataSource());
        dataSourceMap.put("slave", slaveDataSource());
        routingDataSource.setTargetDataSources(dataSourceMap);
        routingDataSource.setDefaultTargetDataSource(masterDataSource());
        return routingDataSource;
    }
}
```

#### 12.2.2 分库分表

**分表策略**:
```java
@Component
public class ShardingStrategy {
    
    public String getTableName(String baseTable, Long userId) {
        int shard = (int) (userId % 4);
        return baseTable + "_" + shard;
    }
    
    public String getDatabaseName(String baseDatabase, Long userId) {
        int shard = (int) (userId % 2);
        return baseDatabase + "_" + shard;
    }
}
```

## 13. 安全防护

### 13.1 接口安全

#### 13.1.1 接口鉴权

**JWT配置**:
```java
@Configuration
public class JwtConfig {
    
    @Value("${jwt.secret}")
    private String secret;
    
    @Value("${jwt.expiration}")
    private Long expiration;
    
    @Bean
    public JwtTokenProvider jwtTokenProvider() {
        return new JwtTokenProvider(secret, expiration);
    }
}
```

**JWT工具类**:
```java
@Component
public class JwtTokenProvider {
    
    private final String secret;
    private final Long expiration;
    
    public JwtTokenProvider(String secret, Long expiration) {
        this.secret = secret;
        this.expiration = expiration;
    }
    
    public String generateToken(Long userId) {
        Date now = new Date();
        Date expiryDate = new Date(now.getTime() + expiration);
        
        return Jwts.builder()
            .setSubject(userId.toString())
            .setIssuedAt(now)
            .setExpiration(expiryDate)
            .signWith(SignatureAlgorithm.HS512, secret)
            .compact();
    }
    
    public Long getUserIdFromToken(String token) {
        Claims claims = Jwts.parser()
            .setSigningKey(secret)
            .parseClaimsJws(token)
            .getBody();
        return Long.parseLong(claims.getSubject());
    }
    
    public boolean validateToken(String token) {
        try {
            Jwts.parser().setSigningKey(secret).parseClaimsJws(token);
            return true;
        } catch (JwtException | IllegalArgumentException e) {
            return false;
        }
    }
}
```

#### 13.1.2 接口限流

**限流配置**:
```java
@Configuration
public class RateLimitConfig {
    
    @Bean
    public RateLimiter rateLimiter() {
        return RateLimiter.create(100.0); // 每秒100个请求
    }
}
```

**限流拦截器**:
```java
@Component
public class RateLimitInterceptor implements HandlerInterceptor {
    
    @Autowired
    private RateLimiter rateLimiter;
    
    @Override
    public boolean preHandle(HttpServletRequest request, HttpServletResponse response, Object handler) {
        if (rateLimiter.tryAcquire()) {
            return true;
        } else {
            response.setStatus(HttpStatus.TOO_MANY_REQUESTS.value());
            return false;
        }
    }
}
```

### 13.2 数据安全

#### 13.2.1 数据加密

**敏感数据加密**:
```java
@Component
public class DataEncryptionService {
    
    private final AESUtil aesUtil;
    
    public DataEncryptionService() {
        this.aesUtil = new AESUtil("your-secret-key");
    }
    
    public String encrypt(String data) {
        return aesUtil.encrypt(data);
    }
    
    public String decrypt(String encryptedData) {
        return aesUtil.decrypt(encryptedData);
    }
}
```

#### 13.2.2 数据脱敏

**数据脱敏工具**:
```java
@Component
public class DataMaskingService {
    
    public String maskPhone(String phone) {
        if (phone == null || phone.length() < 7) {
            return phone;
        }
        return phone.substring(0, 3) + "****" + phone.substring(phone.length() - 4);
    }
    
    public String maskEmail(String email) {
        if (email == null || !email.contains("@")) {
            return email;
        }
        String[] parts = email.split("@");
        String username = parts[0];
        if (username.length() <= 2) {
            return email;
        }
        return username.substring(0, 2) + "***@" + parts[1];
    }
}
```

## 14. 测试策略

### 14.1 单元测试

#### 14.1.1 服务层测试

**测试示例**:
```java
@SpringBootTest
class SeckillActivityServiceTest {
    
    @Autowired
    private SeckillActivityService seckillActivityService;
    
    @MockBean
    private SeckillActivityMapper seckillActivityMapper;
    
    @MockBean
    private RedisTemplate<String, Object> redisTemplate;
    
    @Test
    void testParticipateSeckill_Success() {
        // 准备测试数据
        SeckillParticipateDTO dto = new SeckillParticipateDTO();
        dto.setActivityId(1L);
        dto.setUserId(1L);
        dto.setQuantity(1);
        
        SeckillActivity activity = new SeckillActivity();
        activity.setId(1L);
        activity.setStock(10);
        activity.setStatus(1);
        
        // Mock方法调用
        when(seckillActivityMapper.selectById(1L)).thenReturn(activity);
        when(redisTemplate.opsForValue().get("seckill:stock:1")).thenReturn(10);
        
        // 执行测试
        Result result = seckillActivityService.participateSeckill(dto);
        
        // 验证结果
        assertThat(result.getCode()).isEqualTo(1);
        assertThat(result.getMsg()).isEqualTo("参与成功");
    }
}
```

#### 14.1.2 控制器测试

**测试示例**:
```java
@WebMvcTest(SeckillActivityController.class)
class SeckillActivityControllerTest {
    
    @Autowired
    private MockMvc mockMvc;
    
    @MockBean
    private SeckillActivityService seckillActivityService;
    
    @Test
    void testParticipateSeckill() throws Exception {
        // 准备测试数据
        SeckillParticipateDTO dto = new SeckillParticipateDTO();
        dto.setActivityId(1L);
        dto.setUserId(1L);
        dto.setQuantity(1);
        
        Result expectedResult = Result.success("参与成功");
        when(seckillActivityService.participateSeckill(any())).thenReturn(expectedResult);
        
        // 执行测试
        mockMvc.perform(post("/seckill/participate")
                .contentType(MediaType.APPLICATION_JSON)
                .content(JSON.toJSONString(dto)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.code").value(1))
                .andExpect(jsonPath("$.msg").value("参与成功"));
    }
}
```

### 14.2 集成测试

#### 14.2.1 数据库集成测试

**测试配置**:
```java
@SpringBootTest
@Testcontainers
class DatabaseIntegrationTest {
    
    @Container
    static MySQLContainer<?> mysql = new MySQLContainer<>("mysql:8.0")
            .withDatabaseName("test_sky")
            .withUsername("test")
            .withPassword("test");
    
    @DynamicPropertySource
    static void configureProperties(DynamicPropertyRegistry registry) {
        registry.add("spring.datasource.url", mysql::getJdbcUrl);
        registry.add("spring.datasource.username", mysql::getUsername);
        registry.add("spring.datasource.password", mysql::getPassword);
    }
    
    @Test
    void testDatabaseConnection() {
        // 测试数据库连接
        assertThat(mysql.isRunning()).isTrue();
    }
}
```

#### 14.2.2 Redis集成测试

**测试配置**:
```java
@SpringBootTest
@Testcontainers
class RedisIntegrationTest {
    
    @Container
    static GenericContainer<?> redis = new GenericContainer<>("redis:7-alpine")
            .withExposedPorts(6379);
    
    @DynamicPropertySource
    static void configureProperties(DynamicPropertyRegistry registry) {
        registry.add("spring.redis.host", redis::getHost);
        registry.add("spring.redis.port", () -> redis.getMappedPort(6379));
    }
    
    @Test
    void testRedisConnection() {
        // 测试Redis连接
        assertThat(redis.isRunning()).isTrue();
    }
}
```

### 14.3 性能测试

#### 14.3.1 压力测试

**JMeter测试计划**:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<jmeterTestPlan version="1.2">
  <hashTree>
    <TestPlan testname="Seckill Performance Test">
      <elementProp name="TestPlan.arguments" elementType="Arguments" guiclass="ArgumentsPanel">
        <collectionProp name="Arguments.arguments"/>
      </elementProp>
      <stringProp name="TestPlan.user_define_classpath"></stringProp>
      <boolProp name="TestPlan.functional_mode">false</boolProp>
      <boolProp name="TestPlan.serialize_threadgroups">false</boolProp>
      <elementProp name="TestPlan.arguments" elementType="Arguments" guiclass="ArgumentsPanel">
        <collectionProp name="Arguments.arguments"/>
      </elementProp>
      <stringProp name="TestPlan.user_define_classpath"></stringProp>
      <boolProp name="TestPlan.functional_mode">false</boolProp>
      <boolProp name="TestPlan.serialize_threadgroups">false</boolProp>
    </TestPlan>
  </hashTree>
</jmeterTestPlan>
```

#### 14.3.2 负载测试

**负载测试配置**:
```java
@SpringBootTest
class LoadTest {
    
    @Autowired
    private SeckillActivityService seckillActivityService;
    
    @Test
    void testConcurrentSeckill() throws InterruptedException {
        int threadCount = 100;
        int requestCount = 1000;
        CountDownLatch latch = new CountDownLatch(threadCount);
        AtomicInteger successCount = new AtomicInteger(0);
        AtomicInteger failCount = new AtomicInteger(0);
        
        for (int i = 0; i < threadCount; i++) {
            new Thread(() -> {
                for (int j = 0; j < requestCount / threadCount; j++) {
                    try {
                        SeckillParticipateDTO dto = new SeckillParticipateDTO();
                        dto.setActivityId(1L);
                        dto.setUserId(Thread.currentThread().getId());
                        dto.setQuantity(1);
                        
                        Result result = seckillActivityService.participateSeckill(dto);
                        if (result.getCode() == 1) {
                            successCount.incrementAndGet();
                        } else {
                            failCount.incrementAndGet();
                        }
                    } catch (Exception e) {
                        failCount.incrementAndGet();
                    }
                }
                latch.countDown();
            }).start();
        }
        
        latch.await();
        
        System.out.println("成功: " + successCount.get());
        System.out.println("失败: " + failCount.get());
    }
}
```

通过以上实现，我们建立了一个完整的消息队列异步处理系统，实现了支付和积分服务的解耦，提高了系统的可扩展性和稳定性。