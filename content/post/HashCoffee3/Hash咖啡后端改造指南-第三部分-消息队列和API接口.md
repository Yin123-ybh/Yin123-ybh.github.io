---
title: "Hash咖啡项目后端改造指南 - 第三部分：消息队列和API接口"
date: 2025-01-14
draft: false
tags: ["Java", "Spring Boot", "RabbitMQ", "消息队列", "API接口", "异步处理"]
categories: ["后端开发"]
description: "详细讲解RabbitMQ消息队列配置、消息实体设计、生产者消费者实现和完整的API接口开发"
---

# Hash咖啡项目后端改造指南 - 第三部分：消息队列和API接口

## 目录
1. [消息队列架构设计](#消息队列架构设计)
2. [RabbitMQ配置](#rabbitmq配置)
3. [消息实体类设计](#消息实体类设计)
4. [消息生产者服务](#消息生产者服务)
5. [消息消费者服务](#消息消费者服务)
6. [API接口开发](#api接口开发)
7. [配置文件完善](#配置文件完善)
8. [部署和测试](#部署和测试)

---

## 消息队列架构设计

### 1. 消息队列作用

在秒杀系统中，消息队列主要用于：

- **解耦服务**：支付服务和积分服务解耦
- **异步处理**：订单支付后异步处理积分计算
- **削峰填谷**：应对高并发场景
- **可靠性**：消息持久化和重试机制

### 2. 消息流向图

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   订单支付      │    │   积分计算      │    │   订单超时      │
│   (同步)        │    │   (异步)        │    │   (延迟)        │
└─────────┬───────┘    └─────────┬───────┘    └─────────┬───────┘
          │                      │                      │
          ▼                      ▼                      ▼
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│  Order Pay      │    │  Points Earn    │    │  Order Timeout  │
│  Message        │    │  Message        │    │  Message        │
└─────────┬───────┘    └─────────┬───────┘    └─────────┬───────┘
          │                      │                      │
          └──────────────────────┼──────────────────────┘
                                 │
                    ┌─────────────┴─────────────┐
                    │      RabbitMQ             │
                    │   (消息队列)              │
                    └─────────────┬─────────────┘
                                 │
                    ┌─────────────┴─────────────┐
                    │    消息消费者              │
                    │  (异步处理)               │
                    └───────────────────────────┘
```

---

## RabbitMQ配置

### 1. 添加项目依赖

**修改 `sky-server/pom.xml`：**

```xml
<!-- 在现有依赖后添加以下内容 -->

<!-- RabbitMQ 消息队列 -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-amqp</artifactId>
</dependency>
```

### 2. 创建RabbitMQ配置类

**创建 `sky-server/src/main/java/com/sky/config/RabbitMQConfig.java`：**

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
    
    /**
     * 订单交换机
     */
    @Bean
    public DirectExchange orderExchange() {
        return new DirectExchange(ORDER_EXCHANGE, true, false);
    }
    
    /**
     * 订单队列
     */
    @Bean
    public Queue orderQueue() {
        return QueueBuilder.durable(ORDER_QUEUE)
                .withArgument("x-dead-letter-exchange", ORDER_DLX_EXCHANGE)
                .withArgument("x-dead-letter-routing-key", "order.dlx")
                .build();
    }
    
    /**
     * 订单队列绑定
     */
    @Bean
    public Binding orderBinding() {
        return BindingBuilder.bind(orderQueue()).to(orderExchange()).with(ORDER_ROUTING_KEY);
    }
    
    /**
     * 积分交换机
     */
    @Bean
    public DirectExchange pointsExchange() {
        return new DirectExchange(POINTS_EXCHANGE, true, false);
    }
    
    /**
     * 积分队列
     */
    @Bean
    public Queue pointsQueue() {
        return QueueBuilder.durable(POINTS_QUEUE).build();
    }
    
    /**
     * 积分队列绑定
     */
    @Bean
    public Binding pointsBinding() {
        return BindingBuilder.bind(pointsQueue()).to(pointsExchange()).with(POINTS_ROUTING_KEY);
    }
    
    /**
     * 订单超时交换机
     */
    @Bean
    public DirectExchange orderTimeoutExchange() {
        return new DirectExchange(ORDER_TIMEOUT_EXCHANGE, true, false);
    }
    
    /**
     * 订单超时队列
     */
    @Bean
    public Queue orderTimeoutQueue() {
        return QueueBuilder.durable(ORDER_TIMEOUT_QUEUE)
                .withArgument("x-message-ttl", 15 * 60 * 1000) // 15分钟TTL
                .withArgument("x-dead-letter-exchange", ORDER_DLX_EXCHANGE)
                .withArgument("x-dead-letter-routing-key", "order.timeout")
                .build();
    }
    
    /**
     * 订单超时队列绑定
     */
    @Bean
    public Binding orderTimeoutBinding() {
        return BindingBuilder.bind(orderTimeoutQueue()).to(orderTimeoutExchange()).with(ORDER_TIMEOUT_ROUTING_KEY);
    }
    
    /**
     * 死信交换机
     */
    @Bean
    public DirectExchange orderDlxExchange() {
        return new DirectExchange(ORDER_DLX_EXCHANGE, true, false);
    }
    
    /**
     * 死信队列
     */
    @Bean
    public Queue orderDlxQueue() {
        return QueueBuilder.durable(ORDER_DLX_QUEUE).build();
    }
    
    /**
     * 死信队列绑定
     */
    @Bean
    public Binding orderDlxBinding() {
        return BindingBuilder.bind(orderDlxQueue()).to(orderDlxExchange()).with("order.dlx");
    }
    
    /**
     * JSON消息转换器
     */
    @Bean
    public Jackson2JsonMessageConverter messageConverter() {
        return new Jackson2JsonMessageConverter();
    }
    
    /**
     * RabbitTemplate配置
     */
    @Bean
    public RabbitTemplate rabbitTemplate(ConnectionFactory connectionFactory) {
        RabbitTemplate template = new RabbitTemplate(connectionFactory);
        template.setMessageConverter(messageConverter());
        return template;
    }
    
    /**
     * 消费者容器工厂配置
     */
    @Bean
    public RabbitListenerContainerFactory<?> rabbitListenerContainerFactory(ConnectionFactory connectionFactory) {
        SimpleRabbitListenerContainerFactory factory = new SimpleRabbitListenerContainerFactory();
        factory.setConnectionFactory(connectionFactory);
        
        // 设置并发消费者数量
        factory.setConcurrentConsumers(3);
        factory.setMaxConcurrentConsumers(10);
        
        // 设置预取数量
        factory.setPrefetchCount(1);
        
        // 设置手动确认
        factory.setAcknowledgeMode(AcknowledgeMode.MANUAL);
        
        return factory;
    }
}
```

---

## 消息实体类设计

### 1. 订单支付消息

**创建 `sky-pojo/src/main/java/com/sky/entity/message/OrderPayMessage.java`：**

```java
package com.sky.entity.message;

import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;
import java.io.Serializable;
import java.math.BigDecimal;
import java.time.LocalDateTime;

/**
 * 订单支付消息
 */
@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
public class OrderPayMessage implements Serializable {
    private static final long serialVersionUID = 1L;
    
    /**
     * 订单ID
     */
    private Long orderId;
    
    /**
     * 用户ID
     */
    private Long userId;
    
    /**
     * 支付金额
     */
    private BigDecimal amount;
    
    /**
     * 支付时间
     */
    private LocalDateTime payTime;
    
    /**
     * 支付方式
     */
    private Integer payMethod;
}
```

### 2. 积分获得消息

**创建 `sky-pojo/src/main/java/com/sky/entity/message/PointsEarnMessage.java`：**

```java
package com.sky.entity.message;

import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;
import java.io.Serializable;
import java.time.LocalDateTime;

/**
 * 积分获得消息
 */
@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
public class PointsEarnMessage implements Serializable {
    private static final long serialVersionUID = 1L;
    
    /**
     * 用户ID
     */
    private Long userId;
    
    /**
     * 订单ID
     */
    private Long orderId;
    
    /**
     * 获得积分
     */
    private Integer points;
    
    /**
     * 获得时间
     */
    private LocalDateTime earnTime;
}
```

### 3. 订单超时消息

**创建 `sky-pojo/src/main/java/com/sky/entity/message/OrderTimeoutMessage.java`：**

```java
package com.sky.entity.message;

import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;
import java.io.Serializable;
import java.time.LocalDateTime;

/**
 * 订单超时消息
 */
@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
public class OrderTimeoutMessage implements Serializable {
    private static final long serialVersionUID = 1L;
    
    /**
     * 订单ID
     */
    private Long orderId;
    
    /**
     * 用户ID
     */
    private Long userId;
    
    /**
     * 超时时间
     */
    private LocalDateTime timeoutTime;
}
```

---

## 消息生产者服务

### 1. 创建消息生产者服务接口

**创建 `sky-server/src/main/java/com/sky/service/MessageProducerService.java`：**

```java
package com.sky.service;

import com.sky.entity.message.OrderPayMessage;
import com.sky.entity.message.OrderTimeoutMessage;
import com.sky.entity.message.PointsEarnMessage;

/**
 * 消息生产者服务接口
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

### 2. 创建消息生产者服务实现类

**创建 `sky-server/src/main/java/com/sky/service/impl/MessageProducerServiceImpl.java`：**

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
 */
@Service
@Slf4j
public class MessageProducerServiceImpl implements MessageProducerService {
    
    @Autowired
    private RabbitTemplate rabbitTemplate;
    
    /**
     * 发送订单支付消息
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
            log.info("订单支付消息发送成功：orderId={}, userId={}", message.getOrderId(), message.getUserId());
        } catch (Exception e) {
            log.error("发送订单支付消息失败：{}", e.getMessage(), e);
        }
    }
    
    /**
     * 发送积分获得消息
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
            log.info("积分获得消息发送成功：userId={}, points={}", message.getUserId(), message.getPoints());
        } catch (Exception e) {
            log.error("发送积分获得消息失败：{}", e.getMessage(), e);
        }
    }
    
    /**
     * 发送订单超时消息
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
                    msg.getMessageProperties().setExpiration("900000"); // 15分钟
                    return msg;
                }
            );
            log.info("订单超时消息发送成功：orderId={}, userId={}", message.getOrderId(), message.getUserId());
        } catch (Exception e) {
            log.error("发送订单超时消息失败：{}", e.getMessage(), e);
        }
    }
}
```

---

## 消息消费者服务

### 1. 创建消息消费者服务接口

**创建 `sky-server/src/main/java/com/sky/service/MessageConsumerService.java`：**

```java
package com.sky.service;

import com.sky.entity.message.OrderPayMessage;
import com.sky.entity.message.OrderTimeoutMessage;
import com.sky.entity.message.PointsEarnMessage;

/**
 * 消息消费者服务接口
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

### 2. 创建消息消费者服务实现类

**创建 `sky-server/src/main/java/com/sky/service/impl/MessageConsumerServiceImpl.java`：**

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
 */
@Service
@Slf4j
public class MessageConsumerServiceImpl implements MessageConsumerService {
    
    @Autowired
    private UserService userService;
    
    @Autowired
    private OrderService orderService;
    
    @Autowired
    private MessageProducerService messageProducerService;
    
    /**
     * 处理订单支付消息（RabbitMQ监听器）
     */
    @RabbitListener(queues = "order.queue", containerFactory = "rabbitListenerContainerFactory")
    public void handleOrderPayMessage(OrderPayMessage message, Channel channel, 
                                    @Header("amqp_deliveryTag") long deliveryTag) {
        try {
            // 调用接口方法处理业务逻辑
            handleOrderPayMessage(message);
            
            // 手动确认消息
            channel.basicAck(deliveryTag, false);
            log.info("订单支付消息处理成功：orderId={}", message.getOrderId());
            
        } catch (Exception e) {
            log.error("处理订单支付消息失败：orderId={}, error={}", message.getOrderId(), e.getMessage(), e);
            try {
                // 拒绝消息并重新入队
                channel.basicNack(deliveryTag, false, true);
            } catch (IOException ioException) {
                log.error("拒绝消息失败：{}", ioException.getMessage(), ioException);
            }
        }
    }
    
    /**
     * 处理积分获得消息（RabbitMQ监听器）
     */
    @RabbitListener(queues = "points.queue", containerFactory = "rabbitListenerContainerFactory")
    public void handlePointsEarnMessage(PointsEarnMessage message, Channel channel, 
                                      @Header("amqp_deliveryTag") long deliveryTag) {
        try {
            // 调用接口方法处理业务逻辑
            handlePointsEarnMessage(message);
            
            // 手动确认消息
            channel.basicAck(deliveryTag, false);
            log.info("积分获得消息处理成功：userId={}, points={}", message.getUserId(), message.getPoints());
            
        } catch (Exception e) {
            log.error("处理积分获得消息失败：userId={}, error={}", message.getUserId(), e.getMessage(), e);
            try {
                // 拒绝消息并重新入队
                channel.basicNack(deliveryTag, false, true);
            } catch (IOException ioException) {
                log.error("拒绝消息失败：{}", ioException.getMessage(), ioException);
            }
        }
    }
    
    /**
     * 处理订单超时消息（RabbitMQ监听器）
     */
    @RabbitListener(queues = "order.dlx.queue", containerFactory = "rabbitListenerContainerFactory")
    public void handleOrderTimeoutMessage(OrderTimeoutMessage message, Channel channel, 
                                        @Header("amqp_deliveryTag") long deliveryTag) {
        try {
            // 调用接口方法处理业务逻辑
            handleOrderTimeoutMessage(message);
            
            // 手动确认消息
            channel.basicAck(deliveryTag, false);
            log.info("订单超时消息处理成功：orderId={}", message.getOrderId());
            
        } catch (Exception e) {
            log.error("处理订单超时消息失败：orderId={}, error={}", message.getOrderId(), e.getMessage(), e);
            try {
                // 拒绝消息并重新入队
                channel.basicNack(deliveryTag, false, true);
            } catch (IOException ioException) {
                log.error("拒绝消息失败：{}", ioException.getMessage(), ioException);
            }
        }
    }
    
    /**
     * 处理订单支付消息（业务逻辑）
     */
    @Override
    public void handleOrderPayMessage(OrderPayMessage message) {
        log.info("开始处理订单支付消息：orderId={}, userId={}", message.getOrderId(), message.getUserId());
        
        // 处理订单支付逻辑
        orderService.processOrderPayment(message.getOrderId(), message.getAmount());
        
        // 发送积分获得消息
        PointsEarnMessage pointsMessage = PointsEarnMessage.builder()
                .userId(message.getUserId())
                .orderId(message.getOrderId())
                .points((int) (message.getAmount().doubleValue() * 0.01)) // 1%积分
                .earnTime(message.getPayTime())
                .build();
        
        messageProducerService.sendPointsEarnMessage(pointsMessage);
    }
    
    /**
     * 处理积分获得消息（业务逻辑）
     */
    @Override
    public void handlePointsEarnMessage(PointsEarnMessage message) {
        log.info("开始处理积分获得消息：userId={}, points={}", message.getUserId(), message.getPoints());
        
        // 处理积分获得逻辑
        userService.addUserPoints(message.getUserId(), message.getPoints(), message.getOrderId());
    }
    
    /**
     * 处理订单超时消息（业务逻辑）
     */
    @Override
    public void handleOrderTimeoutMessage(OrderTimeoutMessage message) {
        log.info("开始处理订单超时消息：orderId={}, userId={}", message.getOrderId(), message.getUserId());
        
        // 处理订单超时逻辑
        orderService.cancelTimeoutOrder(message.getOrderId());
    }
}
```

---

## 补充Service接口方法

### 1. 在UserService接口中添加方法

**修改 `sky-server/src/main/java/com/sky/service/UserService.java`：**

```java
package com.sky.service;

import com.sky.dto.UserLoginDTO;
import com.sky.entity.User;

public interface UserService {

    /**
     * 微信登录
     * @param userLoginDTO
     * @return
     */
    User wxLogin(UserLoginDTO userLoginDTO);
    
    /**
     * 添加用户积分
     * @param userId 用户ID
     * @param points 积分数量
     * @param orderId 订单ID
     */
    void addUserPoints(Long userId, Integer points, Long orderId);
}
```

### 2. 在OrderService接口中添加方法

**修改 `sky-server/src/main/java/com/sky/service/OrderService.java`：**

```java
// 在现有方法后添加以下方法

/**
 * 处理订单支付
 * @param orderId 订单ID
 * @param amount 支付金额
 */
void processOrderPayment(Long orderId, BigDecimal amount);

/**
 * 取消超时订单
 * @param orderId 订单ID
 */
void cancelTimeoutOrder(Long orderId);
```

### 3. 在UserServiceImpl中添加实现

**修改 `sky-server/src/main/java/com/sky/service/impl/UserServiceImpl.java`：**

```java
// 在现有方法后添加以下方法

/**
 * 添加用户积分
 * @param userId 用户ID
 * @param points 积分数量
 * @param orderId 订单ID
 */
@Override
public void addUserPoints(Long userId, Integer points, Long orderId) {
    // 查询用户当前积分
    User user = userMapper.getById(userId);
    if (user != null) {
        // 更新用户积分
        userMapper.updateUserPoints(userId, user.getPoints() + points);
        log.info("用户积分增加成功：userId={}, points={}, orderId={}", userId, points, orderId);
    }
}
```

### 4. 在OrderServiceImpl中添加实现

**修改 `sky-server/src/main/java/com/sky/service/impl/OrderServiceImpl.java`：**

```java
// 在现有方法后添加以下方法

/**
 * 处理订单支付
 * @param orderId 订单ID
 * @param amount 支付金额
 */
@Override
public void processOrderPayment(Long orderId, BigDecimal amount) {
    // 更新订单状态为已支付
    Orders orders = Orders.builder()
            .id(orderId)
            .status(Orders.TO_BE_CONFIRMED)
            .payStatus(Orders.PAID)
            .checkoutTime(LocalDateTime.now())
            .build();
    
    orderMapper.update(orders);
    log.info("订单支付处理成功：orderId={}, amount={}", orderId, amount);
}

/**
 * 取消超时订单
 * @param orderId 订单ID
 */
@Override
public void cancelTimeoutOrder(Long orderId) {
    // 查询订单状态
    Orders ordersDB = orderMapper.getById(orderId);
    if (ordersDB != null && ordersDB.getStatus().equals(Orders.PENDING_PAYMENT)) {
        // 更新订单状态为已取消
        Orders orders = Orders.builder()
                .id(orderId)
                .status(Orders.CANCELLED)
                .cancelReason("订单超时自动取消")
                .cancelTime(LocalDateTime.now())
                .build();
        
        orderMapper.update(orders);
        log.info("订单超时取消成功：orderId={}", orderId);
    }
}
```

### 5. 添加Mapper方法

**在 `UserMapper.java` 中添加：**
```java
/**
 * 更新用户积分
 * @param userId 用户ID
 * @param points 新积分
 */
void updateUserPoints(@Param("userId") Long userId, @Param("points") Integer points);
```

**在 `UserMapper.xml` 中添加：**
```xml
<update id="updateUserPoints">
    UPDATE user SET points = #{points} WHERE id = #{userId}
</update>
```

---

## API接口开发

### 1. 用户端秒杀控制器

**创建 `sky-server/src/main/java/com/sky/controller/user/SeckillActivityController.java`：**

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
 */
@RestController
@RequestMapping("/user/seckill/activity")
@Api(tags = "用户端秒杀活动")
@Slf4j
public class SeckillActivityController {

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

### 2. 用户端优惠券控制器

**创建 `sky-server/src/main/java/com/sky/controller/user/CouponController.java`：**

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

import java.util.List;

/**
 * 用户端优惠券控制器
 */
@RestController
@RequestMapping("/user/coupon")
@Api(tags = "用户端优惠券")
@Slf4j
public class CouponController {

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
        List<Coupon> coupons = couponService.getUserCoupons(userId);
        return Result.success(coupons);
    }
}
```

### 3. 健康检查控制器

**创建 `sky-server/src/main/java/com/sky/controller/HealthController.java`：**

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
        
        result.put("status", "UP");
        result.put("timestamp", System.currentTimeMillis());
        
        return result;
    }
}
```

---

## 配置文件完善

### 1. 更新application.yml

**修改 `sky-server/src/main/resources/application.yml`：**

```yaml
server:
  port: 8084

spring:
  application:
    name: sky-server
  
  # 数据库配置
  datasource:
    druid:
      driver-class-name: com.mysql.cj.jdbc.Driver
      url: jdbc:mysql://localhost:3306/pet-cafe-shop?useUnicode=true&characterEncoding=utf-8&useSSL=false&serverTimezone=GMT%2B8
      username: root
      password: 123456

  # Redis配置
  redis:
    host: localhost
    port: 6379
    password: 
    database: 0
    timeout: 5000ms
    lettuce:
      pool:
        max-active: 8
        max-wait: -1ms
        max-idle: 8
        min-idle: 0

  # RabbitMQ配置
  rabbitmq:
    host: localhost
    port: 5672
    username: guest
    password: guest
    virtual-host: /
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

# MyBatis配置
mybatis:
  mapper-locations: classpath:mapper/*.xml
  type-aliases-package: com.sky.entity
  configuration:
    map-underscore-to-camel-case: true
    log-impl: org.apache.ibatis.logging.stdout.StdOutImpl

# 日志配置
logging:
  level:
    com.sky: debug
    org.springframework.amqp: debug
  pattern:
    console: "%d{yyyy-MM-dd HH:mm:ss} [%thread] %-5level %logger{36} - %msg%n"
    file: "%d{yyyy-MM-dd HH:mm:ss} [%thread] %-5level %logger{36} - %msg%n"
  file:
    name: logs/sky-server.log
    max-size: 100MB
    max-history: 30
```

### 2. 创建Redisson配置

**创建 `sky-server/src/main/java/com/sky/config/RedissonConfig.java`：**

```java
package com.sky.config;

import org.redisson.Redisson;
import org.redisson.api.RedissonClient;
import org.redisson.config.Config;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Redisson配置
 */
@Configuration
public class RedissonConfig {
    
    @Value("${spring.redis.host}")
    private String host;
    
    @Value("${spring.redis.port}")
    private int port;
    
    @Value("${spring.redis.password:}")
    private String password;
    
    @Value("${spring.redis.database:0}")
    private int database;
    
    @Bean
    public RedissonClient redissonClient() {
        Config config = new Config();
        String address = "redis://" + host + ":" + port;
        
        config.useSingleServer()
                .setAddress(address)
                .setPassword(password.isEmpty() ? null : password)
                .setDatabase(database)
                .setConnectionPoolSize(64)
                .setConnectionMinimumIdleSize(10)
                .setIdleConnectionTimeout(10000)
                .setConnectTimeout(10000)
                .setTimeout(3000)
                .setRetryAttempts(3)
                .setRetryInterval(1500);
        
        return Redisson.create(config);
    }
}
```

---

## 部署和测试

### 1. 启动顺序

1. **启动基础服务**：
   ```bash
   # 启动MySQL
   docker run -d --name mysql -p 3306:3306 -e MYSQL_ROOT_PASSWORD=123456 mysql:8.0
   
   # 启动Redis
   docker run -d --name redis -p 6379:6379 redis:6.2-alpine
   
   # 启动RabbitMQ
   docker run -d --name rabbitmq -p 5672:5672 -p 15672:15672 rabbitmq:3.9-management-alpine
   ```

2. **导入数据库**：
   ```bash
   mysql -u root -p123456 pet-cafe-shop < script3.sql
   ```

3. **启动后端服务**：
   ```bash
   cd sky-server
   mvn spring-boot:run
   ```

### 2. 测试接口

**测试秒杀活动接口**：
```bash
# 获取当前秒杀活动
curl -X GET "http://localhost:8084/user/seckill/activity/current"

# 参与秒杀活动
curl -X POST "http://localhost:8084/user/seckill/activity/participate/1?quantity=1" \
     -H "userId: 1"
```

**测试优惠券接口**：
```bash
# 获取可领取的优惠券
curl -X GET "http://localhost:8084/user/coupon/templates/available"

# 领取优惠券
curl -X POST "http://localhost:8084/user/coupon/claim?templateId=1" \
     -H "userId: 1"
```

**测试健康检查**：
```bash
# 健康检查
curl -X GET "http://localhost:8084/health/check"
```

### 3. 消息队列测试

**访问RabbitMQ管理界面**：
- 地址：http://localhost:15672
- 用户名：guest
- 密码：guest

在管理界面中可以查看：
- 队列状态
- 消息数量
- 消费者连接
- 消息路由情况

---

## 核心特性总结

### 1. 消息队列特性

- **可靠性**：消息持久化，确保消息不丢失
- **解耦性**：支付服务和积分服务完全解耦
- **异步性**：提高系统响应速度
- **削峰填谷**：应对高并发场景

### 2. API接口特性

- **RESTful设计**：符合REST规范
- **统一响应格式**：使用Result统一封装
- **Swagger文档**：自动生成API文档
- **健康检查**：系统状态监控

### 3. 配置管理

- **环境隔离**：支持多环境配置
- **外部化配置**：配置与代码分离
- **热更新**：支持配置动态更新

---

## 总结

第三部分完成了消息队列架构和API接口的开发，包括：

✅ **RabbitMQ配置** - 完整的消息队列配置
✅ **消息实体设计** - 订单支付、积分获得、订单超时消息
✅ **生产者消费者** - 消息发送和接收处理
✅ **API接口开发** - 用户端秒杀和优惠券接口
✅ **配置文件完善** - 完整的应用配置
✅ **部署测试** - 启动和测试方案

整个后端改造指南的三个部分已经完成，涵盖了从数据库设计到API接口的完整开发流程。你可以按照这个指南逐步实现一个完整的分布式秒杀系统。

---

*相关阅读：*
- [Hash咖啡后端改造指南 - 第一部分：项目概述和数据库设计](./Hash咖啡后端改造指南-第一部分-项目概述和数据库设计.md)
- [Hash咖啡后端改造指南 - 第二部分：实体类和分布式锁实现](./Hash咖啡后端改造指南-第二部分-实体类和分布式锁实现.md)
