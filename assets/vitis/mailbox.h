/**
 * @file mailbox.h
 * @brief Simple inter-core mailbox implementation for AMP systems.
 *
 * This mailbox provides communication between two CPUs through a shared
 * memory region and optional Software Generated Interrupts (SGIs).
 *
 * The implementation follows a simple single-producer/single-consumer model:
 *
 * @code
 * CPU0 -----> MAILBOX_TO_CPU1
 * CPU1 -----> MAILBOX_TO_CPU0
 * @endcode
 *
 * Communication is performed by exchanging messages through shared memory.
 * Each mailbox can hold a single message at a time.
 *
 * Typical usage:
 *
 * @code
 * // CPU0 initializes MAILBOX_TO_CPU0
 * mailbox_init(MAILBOX_TO_CPU0);
 *
 * // CPU0 sends messages to CPU1 via MAILBOX_TO_CPU1
 * uint32_t value = 1;
 * mailbox_send_and_notify(MAILBOX_TO_CPU1, MAILBOX_MSG_LED, &value, sizeof(value));
 * @endcode
 */

#ifndef MAILBOX_H
#define MAILBOX_H

#include <stdbool.h>
#include <stdint.h>

/**
 * @brief Maximum mailbox payload size in bytes.
 *
 * Each mailbox message may carry up to this amount of user data.
 *
 * @warning Increasing this value increases mailbox memory consumption.
 * Ensure that mailboxes do not overlap inside the shared memory region.
 */
#define MAILBOX_MAX_PAYLOAD_SIZE 256

/**
 * @brief Message type identifiers.
 *
 * The message code determines how a payload should be interpreted by the receiving CPU.
 *
 * Users are expected to extend this enumeration with application-specific message types.
 */
typedef enum mailbox_msg_code_t
{
    /** No message / invalid message */
    MAILBOX_MSG_NONE = 0,
    /** Simple LED control message */
    MAILBOX_MSG_LED = 1,
    /* USER: add here as many message codes as you need */
} mailbox_msg_code_t;

/**
 * @brief Mailbox identifier.
 *
 * Mailbox ownership follows the convention:
 *
 * @code
 * MAILBOX_TO_CPU0:
 *     Written by CPU1
 *     Read by CPU0
 *
 * MAILBOX_TO_CPU1:
 *     Written by CPU0
 *     Read by CPU1
 * @endcode
 */
typedef enum mailbox_id_t
{
    /** Mailbox whose destination is CPU0 */
    MAILBOX_TO_CPU0 = 0,
    /** Mailbox whose destination is CPU1 */
    MAILBOX_TO_CPU1 = 1,
} mailbox_id_t;

/**
 * @brief Mailbox operation result.
 */
typedef enum mailbox_result_t
{
    /** Operation completed successfully */
    MAILBOX_OK = 0,
    /** Invalid mailbox identifier */
    MAILBOX_INVALID_ID,
    /** Failed to encode SGI interrupt identifier */
    MAILBOX_INTR_ENCODING_FAILED,
    /** Failed to configure SGI interrupt callback */
    MAILBOX_INTR_SETUP_FAILED,
    /** Mailbox already contains a message */
    MAILBOX_MAILBOX_FULL,
    /** Mailbox contains no message */
    MAILBOX_MAILBOX_EMPTY,
    /** Message code does not match expectations */
    MAILBOX_CODE_INVALID,
    /** Message payload is invalid */
    MAILBOX_INVALID_PAYLOAD,
    /** Failed to generate SGI notification */
    MAILBOX_NOTIFY_FAILED
} mailbox_result_t;

/**
 * @brief Generic mailbox message.
 *
 * Messages are composed of:
 *  - a message code identifying the payload type;
 *  - a payload size in bytes;
 *  - a payload buffer containing user-defined data.
 */
typedef struct mailbox_message_t
{
    /**
     * @brief Message identifier.
     *
     * One of the values defined in mailbox_msg_code_t.
     */
    uint16_t code;
    /**
     * @brief Number of valid bytes in payload.
     */
    uint16_t size;
    /**
     * @brief User payload.
     */
    uint8_t payload[MAILBOX_MAX_PAYLOAD_SIZE];
} mailbox_message_t;

/**
 * @brief SGI callback prototype.
 *
 * This callback will be executed when a mailbox notification interrupt is received.
 *
 * @param p_arg User-provided callback argument.
 */
typedef void (*mailbox_callback_t)(void *);

/**
 * @brief Initializes a mailbox.
 *
 * This function:
 *  - configures the shared memory region as non-cacheable and shareable;
 *  - clears the destination mailbox state;
 *  - prepares the mailbox for communication.
 *
 * Each CPU should initialize its own destination mailbox.
 *
 * @param mailbox_id Mailbox to initialize.
 *
 * @retval MAILBOX_OK Initialization completed successfully.
 * @retval MAILBOX_INVALID_ID Invalid mailbox identifier.
 */
mailbox_result_t mailbox_init(mailbox_id_t mailbox_id);

/**
 * @brief Registers the mailbox notification callback.
 *
 * Internally configures a Software Generated Interrupt (SGI) used
 * to wake the destination CPU when a message becomes available.
 *
 * @param p_callback Interrupt callback function.
 * @param p_arg User callback argument.
 *
 * @retval MAILBOX_OK Callback installed successfully.
 * @retval MAILBOX_INTR_ENCODING_FAILED Failed to encode SGI interrupt ID.
 * @retval MAILBOX_INTR_SETUP_FAILED Failed to configure interrupt system.
 */
mailbox_result_t mailbox_setup_callback(mailbox_callback_t p_callback, void *p_arg);

/**
 * @brief Sends a message to a mailbox.
 *
 * The message is copied into shared memory. The mailbox must be empty before sending.
 *
 * This function only transfers the data. It does not notify the receiving CPU.
 *
 * @param mailbox_id Destination mailbox.
 * @param code Message code.
 * @param p_payload Pointer to payload buffer.
 * @param size Payload size in bytes.
 *
 * @retval MAILBOX_OK Message successfully written.
 * @retval MAILBOX_INVALID_ID Invalid mailbox identifier.
 * @retval MAILBOX_INVALID_PAYLOAD Payload invalid or too large.
 * @retval MAILBOX_MAILBOX_FULL Mailbox already contains data.
 */
mailbox_result_t mailbox_send(mailbox_id_t mailbox_id, mailbox_msg_code_t code, const void *p_payload, uint16_t size);

/**
 * @brief Notifies the destination CPU.
 *
 * Triggers a Software Generated Interrupt (SGI) corresponding to the destination mailbox.
 *
 * @param mailbox_id Destination mailbox.
 *
 * @retval MAILBOX_OK Notification generated successfully.
 * @retval MAILBOX_INVALID_ID Invalid mailbox identifier.
 * @retval MAILBOX_NOTIFY_FAILED Notification generation failed.
 */
mailbox_result_t mailbox_notify(mailbox_id_t mailbox_id);

/**
 * @brief Sends a message and notifies the receiver.
 *
 * Convenience function equivalent to:
 *
 * @code
 * mailbox_send(...);
 * mailbox_notify(...);
 * @endcode
 *
 * @param mailbox_id Destination mailbox.
 * @param code Message code.
 * @param p_payload Pointer to payload buffer.
 * @param size Payload size in bytes.
 *
 * @return Operation result.
 */
mailbox_result_t mailbox_send_and_notify(mailbox_id_t mailbox_id, mailbox_msg_code_t code, const void *p_payload, uint16_t size);

/**
 * @brief Removes the current message from a mailbox.
 *
 * After successful completion, the mailbox becomes available for new messages.
 *
 * @param mailbox_id Target mailbox.
 *
 * @retval MAILBOX_OK Mailbox cleared successfully.
 * @retval MAILBOX_INVALID_ID Invalid mailbox identifier.
 * @retval MAILBOX_MAILBOX_EMPTY Mailbox already empty.
 */
mailbox_result_t mailbox_clear(mailbox_id_t);

/**
 * @brief Returns a read-only pointer to the current mailbox message.
 *
 * This function provides zero-copy access to mailbox contents.
 * The returned pointer remains valid only while the mailbox contains the message.
 *
 * The returned message must never be modified.
 *
 * @param mailbox_id Target mailbox.
 * @param pp_message Output pointer receiving the message address.
 *
 * @retval MAILBOX_OK Message available.
 * @retval MAILBOX_INVALID_ID Invalid mailbox identifier.
 * @retval MAILBOX_MAILBOX_EMPTY Mailbox empty.
 */
mailbox_result_t mailbox_peek(mailbox_id_t mailbox_id, const mailbox_message_t **pp_message);

/**
 * @brief Retrieves only the message code.
 *
 * Useful when dispatching messages without reading the whole payload.
 *
 * @param mailbox_id Target mailbox.
 * @param p_code Output message code.
 *
 * @retval MAILBOX_OK Message available.
 * @retval MAILBOX_INVALID_ID Invalid mailbox identifier.
 * @retval MAILBOX_MAILBOX_EMPTY Mailbox empty.
 */
mailbox_result_t mailbox_peek_code(mailbox_id_t mailbox_id, mailbox_msg_code_t *p_code);

/**
 * @brief Receives a mailbox message.
 *
 * The message is copied into user memory and the mailbox is cleared.
 *
 * @param mailbox_id Target mailbox.
 * @param p_message Destination message structure.
 *
 * @retval MAILBOX_OK Message successfully received.
 * @retval MAILBOX_INVALID_ID Invalid mailbox identifier.
 * @retval MAILBOX_MAILBOX_EMPTY Mailbox empty.
 */
mailbox_result_t mailbox_recv(mailbox_id_t mailbox_id, mailbox_message_t *p_message);

#endif // MAILBOX_H
