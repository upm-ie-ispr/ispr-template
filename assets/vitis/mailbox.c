#include "mailbox.h"
#include "xil_mmu.h"
#include "xpseudo_asm.h"
#include "xinterrupt_wrap.h"
#include <stdint.h>

typedef enum mailbox_state_t
{
    MAILBOX_EMPTY = 0,
    MAILBOX_FULL = 1,
} mailbox_state_t;

typedef struct mailbox_t
{
    volatile mailbox_state_t state;
    mailbox_message_t message;
} mailbox_t;

/* Shared memory region (last 1 MiB of DDR) */
#define SHARED_MEM_START 0x1FF00000
#define SHARED_MEM_SIZE 0x00100000

/* Mailboxes are placed at the beginning of each half of the shared memory region. */
#define MAILBOX_REGION_SIZE ((SHARED_MEM_SIZE) / 2)

/* We use SGI number 1 for mailbox communication */
#define MAILBOX_SGI_ID 1

/* Pointers to CPU mailboxes */
#define P_MAILBOX_TO_CPU0 ((mailbox_t *)(SHARED_MEM_START))
#define P_MAILBOX_TO_CPU1 ((mailbox_t *)(SHARED_MEM_START + MAILBOX_REGION_SIZE))

_Static_assert((SHARED_MEM_START & 0xFFFFFU) == 0, "Shared memory must be 1 MiB aligned");
_Static_assert((SHARED_MEM_SIZE & 0xFFFFFU) == 0, "Shared memory size must be a multiple of 1 MiB");

static inline mailbox_t *mailbox_get(mailbox_id_t mailbox_id)
{
    switch (mailbox_id)
    {
    case MAILBOX_TO_CPU0:
        return P_MAILBOX_TO_CPU0;
    case MAILBOX_TO_CPU1:
        return P_MAILBOX_TO_CPU1;
    default:
        return NULL;
    }
}

static inline uint32_t mailbox_get_sgi_mask(mailbox_id_t mailbox_id)
{
    switch (mailbox_id)
    {
    case MAILBOX_TO_CPU0:
        return 0x1;
    case MAILBOX_TO_CPU1:
        return 0x2;
    default:
        return 0;
    }
}

mailbox_result_t mailbox_init(mailbox_id_t mailbox_id)
{
    // Make sure mailbox ID is valid
    mailbox_t *p_mailbox = mailbox_get(mailbox_id);
    if (p_mailbox == NULL)
    {
        return MAILBOX_INVALID_ID;
    }
    // Set all 1MiB sections comprising shared DDR as non-cacheable, shareable memory
    for (uint32_t addr = SHARED_MEM_START; addr < SHARED_MEM_START + SHARED_MEM_SIZE; addr += 0x00100000U)
    {
        Xil_SetTlbAttributes(addr, NORM_NONCACHE | SHAREABLE);
    }
    // Each CPU initializes its destination mailbox
    p_mailbox->state = MAILBOX_EMPTY;
    p_mailbox->message.code = 0;
    p_mailbox->message.size = 0;
    dmb(); // data memory barrier
    return MAILBOX_OK;
}

mailbox_result_t mailbox_setup_callback(mailbox_callback_t p_callback, void *p_arg)
{
    // Codify corresponding SGI interrupt ID
    uint32_t interrupt_id;
    int result = XGetEncodedIntrId(MAILBOX_SGI_ID, 0, XSGI, XINTC_TYPE_IS_SCUGIC, &interrupt_id);
    if (result != XST_SUCCESS)
    {
        return MAILBOX_INTR_ENCODING_FAILED;
    }
    // Enable SGI interrupt
    result = XSetupInterruptSystem(p_arg, p_callback, interrupt_id, XPAR_XSCUGIC_0_BASEADDR, XINTERRUPT_DEFAULT_PRIORITY);
    if (result != XST_SUCCESS)
    {
        return MAILBOX_INTR_SETUP_FAILED;
    }
    return MAILBOX_OK;
}

mailbox_result_t mailbox_send(mailbox_id_t mailbox_id, mailbox_msg_code_t code, const void *p_payload, uint16_t size)
{
    // Make sure mailbox ID is valid
    mailbox_t *p_mailbox = mailbox_get(mailbox_id);
    if (p_mailbox == NULL)
    {
        return MAILBOX_INVALID_ID;
    }
    // Make sure it fits in mailbox
    if (size > MAILBOX_MAX_PAYLOAD_SIZE)
    {
        return MAILBOX_INVALID_PAYLOAD;
    }
    // Make sure payload pointer is valid if size > 0
    if ((size > 0) && (p_payload == NULL))
    {
        return MAILBOX_INVALID_PAYLOAD;
    }
    // Make sure mailbox is empty
    if (p_mailbox->state != MAILBOX_EMPTY)
    {
        return MAILBOX_MAILBOX_FULL;
    }
    // Write data to mailbox
    p_mailbox->message.code = code;
    p_mailbox->message.size = size;
    if ((size > 0) && (p_payload != NULL))
    {
        memcpy(p_mailbox->message.payload, p_payload, size);
    }
    dmb(); // data memory barrier
    p_mailbox->state = MAILBOX_FULL;
    return MAILBOX_OK;
}

mailbox_result_t mailbox_notify(mailbox_id_t mailbox_id)
{
    // Make sure mailbox ID is valid
    uint32_t sgi_mask = mailbox_get_sgi_mask(mailbox_id);
    if (sgi_mask == 0)
    {
        return MAILBOX_INVALID_ID;
    }
    int result = XTriggerSoftwareIntr(MAILBOX_SGI_ID, XPAR_XSCUGIC_0_BASEADDR, sgi_mask);
    if (result != XST_SUCCESS)
    {
        return MAILBOX_NOTIFY_FAILED;
    }
    return MAILBOX_OK;
}

mailbox_result_t mailbox_send_and_notify(mailbox_id_t mailbox_id, mailbox_msg_code_t code, const void *p_payload, uint16_t size)
{
    mailbox_result_t res = mailbox_send(mailbox_id, code, p_payload, size);
    if (res == MAILBOX_OK)
    {
        res = mailbox_notify(mailbox_id);
    }
    return res;
}

mailbox_result_t mailbox_clear(mailbox_id_t mailbox_id)
{
    // Make sure mailbox ID is valid
    mailbox_t *p_mailbox = mailbox_get(mailbox_id);
    if (p_mailbox == NULL)
    {
        return MAILBOX_INVALID_ID;
    }
    if (p_mailbox->state != MAILBOX_FULL)
    {
        return MAILBOX_MAILBOX_EMPTY;
    }
    p_mailbox->message.code = MAILBOX_MSG_NONE;
    p_mailbox->message.size = 0;
    dmb(); // data memory barrier
    p_mailbox->state = MAILBOX_EMPTY;
    return MAILBOX_OK;
}

mailbox_result_t mailbox_peek(mailbox_id_t mailbox_id, const mailbox_message_t **pp_message)
{
    // Make sure mailbox ID is valid
    mailbox_t *p_mailbox = mailbox_get(mailbox_id);
    if (p_mailbox == NULL)
    {
        return MAILBOX_INVALID_ID;
    }
    if (p_mailbox->state != MAILBOX_FULL)
    {
        return MAILBOX_MAILBOX_EMPTY;
    }
    dmb(); // data memory barrier
    *pp_message = &(p_mailbox->message);
    return MAILBOX_OK;
}

mailbox_result_t mailbox_peek_code(mailbox_id_t mailbox_id, mailbox_msg_code_t *p_code)
{
    const mailbox_message_t *p_message;
    mailbox_result_t result = mailbox_peek(mailbox_id, &p_message);
    if (result == MAILBOX_OK)
    {
        *p_code = p_message->code;
    }
    return result;
}

mailbox_result_t mailbox_recv(mailbox_id_t mailbox_id, mailbox_message_t *p_message)
{
    // Peek target mailbox
    const mailbox_message_t *p_from;
    mailbox_result_t result = mailbox_peek(mailbox_id, &p_from);
    if (result != MAILBOX_OK)
    {
        return result;
    }
    // Copy data to p_message
    p_message->code = p_from->code;
    p_message->size = p_from->size;
    memcpy(p_message->payload, p_from->payload, p_message->size);

    // Clear message from mailbox
    return mailbox_clear(mailbox_id);
}
