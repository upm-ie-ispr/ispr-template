/**
 * @file mailbox_user.h
 * @brief Example application-specific mailbox protocol.
 *
 * This file demonstrates how to build strongly-typed messages on top of the
 * generic mailbox transport layer.
 *
 * The generic mailbox API only moves messages between CPUs. User protocols
 * are responsible for defining:
 *
 * - message codes;
 * - payload layouts;
 * - serialization and deserialization helpers.
 *
 * This example implements a simple LED message that transfers a single
 * uint32_t value between CPUs.
 *
 * Example usage:
 *
 * @code
 * uint32_t led_state = 1;
 *
 * mailbox_user_msg_led_send(
 *     MAILBOX_TO_CPU0,
 *     led_state);
 * @endcode
 *
 * Receiving side:
 *
 * @code
 * uint32_t led_state;
 *
 * if (mailbox_user_msg_led_recv(
 *         MAILBOX_TO_CPU0,
 *         &led_state) == MAILBOX_OK)
 * {
 *     // Process LED state
 * }
 * @endcode
 *
 * Students are encouraged to use this file as a template when defining
 * their own mailbox message types.
 */

#ifndef MAILBOX_USER_H
#define MAILBOX_USER_H

#include "mailbox.h"
#include "stdint.h"

/**
 * @brief Sends an LED message.
 *
 * This helper wraps mailbox_send() and automatically encodes the payload
 * using the MAILBOX_MSG_LED message code.
 *
 * The payload consists of a single uint32_t value.
 *
 * Typical interpretations may include:
 * - LED state (0 = OFF, 1 = ON)
 * - LED brightness
 * - LED identifier
 *
 * depending on the application protocol.
 *
 * @param mailbox_id Destination mailbox.
 * @param msg LED message value.
 *
 * @retval MAILBOX_OK Message successfully sent.
 * @retval MAILBOX_INVALID_ID Invalid mailbox identifier.
 * @retval MAILBOX_MAILBOX_FULL Mailbox already contains a message.
 * @retval MAILBOX_INVALID_PAYLOAD Invalid payload.
 */
mailbox_result_t mailbox_user_msg_led_send(mailbox_id_t mailbox_id, uint32_t msg);

/**
 * @brief Receives an LED message.
 *
 * This helper validates that:
 * - the mailbox contains a message;
 * - the message code is MAILBOX_MSG_LED;
 * - the payload size matches sizeof(uint32_t).
 *
 * On success, the payload is decoded and copied into p_msg.
 *
 * The mailbox is cleared after successful reception.
 *
 * @param mailbox_id Source mailbox.
 * @param p_msg Destination variable receiving the LED value.
 *
 * @retval MAILBOX_OK Message successfully received.
 * @retval MAILBOX_INVALID_ID Invalid mailbox identifier.
 * @retval MAILBOX_MAILBOX_EMPTY Mailbox contains no message.
 * @retval MAILBOX_CODE_INVALID Message code does not match MAILBOX_MSG_LED.
 * @retval MAILBOX_INVALID_PAYLOAD Payload size is invalid.
 */
mailbox_result_t mailbox_user_msg_led_recv(mailbox_id_t mailbox_id, uint32_t *p_msg);

#endif // MAILBOX_USER_H
