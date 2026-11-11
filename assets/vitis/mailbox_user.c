#include <memory.h>
#include "mailbox_user.h"
#include "mailbox.h"

mailbox_result_t mailbox_user_msg_led_send(mailbox_id_t mailbox_id, uint32_t msg)
{
    return mailbox_send(mailbox_id, MAILBOX_MSG_LED, &msg, sizeof(uint32_t));
}

mailbox_result_t mailbox_user_msg_led_recv(mailbox_id_t mailbox_id, uint32_t *p_msg)
{
    const mailbox_message_t *p_message;
    mailbox_result_t result = mailbox_peek(mailbox_id, &p_message);
    if (result != MAILBOX_OK)
    {
        return result;
    }
    if (p_message->code != MAILBOX_MSG_LED)
    {
        return MAILBOX_CODE_INVALID;
    }
    if (p_message->size != sizeof(uint32_t))
    {
        return MAILBOX_INVALID_PAYLOAD;
    }
    memcpy(p_msg, p_message->payload, sizeof(uint32_t));
    return mailbox_clear(mailbox_id);
}
