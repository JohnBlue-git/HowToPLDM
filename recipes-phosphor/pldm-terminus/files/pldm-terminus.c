/* pldm-terminus.c
 * Minimal PLDM base-type responder over AF_MCTP for QEMU loopback testing.
 * Binds to EID 10 on MCTP net, responds to GetTID, GetPLDMTypes,
 * GetPLDMVersion so that pldmd can complete its discovery sequence.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/socket.h>
#include <linux/mctp.h>

/* PLDM message type for MCTP */
#define MCTP_TYPE_PLDM          0x01

/* This terminus's EID and TID */
#define TERMINUS_EID            10
#define TERMINUS_TID            1

/* PLDM base (type 0) command codes */
#define PLDM_CMD_GET_TID        0x02
#define PLDM_CMD_GET_PLDM_TYPES 0x04
#define PLDM_CMD_GET_PLDM_VER   0x03

/* PLDM completion codes */
#define CC_SUCCESS              0x00
#define CC_UNSUPPORTED_CMD      0x05
#define CC_INVALID_PLDM_TYPE    0x83

#define MAX_MSG 256

int main(void)
{
    int fd;
    struct sockaddr_mctp addr, peer;
    socklen_t peerlen;
    uint8_t buf[MAX_MSG];
    uint8_t resp[MAX_MSG];
    ssize_t n;
    int rlen;

    fd = socket(AF_MCTP, SOCK_DGRAM, 0);
    if (fd < 0) {
        perror("socket");
        return 1;
    }

    memset(&addr, 0, sizeof(addr));
    addr.smctp_family      = AF_MCTP;
    addr.smctp_network     = MCTP_NET_ANY;
    addr.smctp_addr.s_addr = TERMINUS_EID;
    addr.smctp_type        = MCTP_TYPE_PLDM;
    addr.smctp_tag         = MCTP_TAG_OWNER; /* receive tag-owner (TO=1) requests */

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        close(fd);
        return 1;
    }

    printf("pldm-terminus: bound to EID %d, type PLDM\n", TERMINUS_EID);
    fflush(stdout);

    for (;;) {
        peerlen = sizeof(peer);
        n = recvfrom(fd, buf, sizeof(buf), 0,
                     (struct sockaddr *)&peer, &peerlen);
        if (n < 0) {
            perror("recvfrom");
            continue;
        }
        if (n < 3) {
            fprintf(stderr, "pldm-terminus: short msg (%zd bytes), ignored\n", n);
            continue;
        }

        /* PLDM header layout:
         *   [0] Rq(7) D(6) InstanceID(5:0)
         *   [1] Hdr_ver(7:6) PLDM_type(5:0)
         *   [2] Command code
         *   [3..] Command data
         */
        uint8_t instance_id = buf[0] & 0x1f;
        uint8_t pldm_type   = buf[1] & 0x3f;
        uint8_t cmd         = buf[2];

        printf("pldm-terminus: req EID=%u type=%u cmd=0x%02x instance=%u\n",
               peer.smctp_addr.s_addr, pldm_type, cmd, instance_id);
        fflush(stdout);

        /* Common response header: Rq=0, D=0 */
        resp[0] = instance_id;
        resp[1] = buf[1];   /* preserve hdr_ver + type */
        resp[2] = cmd;
        rlen    = 0;

        if (pldm_type == 0x00) { /* PLDM Base type */
            switch (cmd) {

            case PLDM_CMD_GET_TID:
                resp[3] = CC_SUCCESS;
                resp[4] = TERMINUS_TID;
                rlen = 5;
                break;

            case PLDM_CMD_GET_PLDM_TYPES: {
                uint8_t types[8] = {0};
                types[0] = (1 << 0);    /* bit 0: base type supported */
                resp[3] = CC_SUCCESS;
                memcpy(&resp[4], types, 8);
                rlen = 12;
                break;
            }

            case PLDM_CMD_GET_PLDM_VER:
                /*
                 * Request: TransferOpFlag(1) DataTransferHandle(4) PLDMType(1)
                 * Response: CC(1) NextHandle(4) TransferFlag(1) Version(4)
                 */
                if (n < 7) {
                    resp[3] = CC_UNSUPPORTED_CMD;
                    rlen = 4;
                    break;
                }
                if (buf[6] != 0x00) { /* only base type (0) known */
                    resp[3] = CC_INVALID_PLDM_TYPE;
                    rlen = 4;
                    break;
                }
                resp[3] = CC_SUCCESS;
                /* NextDataTransferHandle = 0 */
                resp[4] = 0x00; resp[5] = 0x00;
                resp[6] = 0x00; resp[7] = 0x00;
                /* TransferFlag = 0x05 (Start and End) */
                resp[8] = 0x05;
                /* PLDM base spec version 1.1.0: encoded as F1 F1 F0 00 */
                resp[9]  = 0xF1;
                resp[10] = 0xF1;
                resp[11] = 0xF0;
                resp[12] = 0x00;
                rlen = 13;
                break;

            default:
                resp[3] = CC_UNSUPPORTED_CMD;
                rlen = 4;
                break;
            }
        } else {
            resp[3] = CC_UNSUPPORTED_CMD;
            rlen = 4;
        }

        if (rlen > 0) {
            /* Response: clear MCTP_TAG_OWNER (TO=0, tag value preserved) */
            peer.smctp_tag &= ~MCTP_TAG_OWNER;
            if (sendto(fd, resp, rlen, 0,
                       (struct sockaddr *)&peer, peerlen) < 0)
                perror("sendto");
        }
    }

    close(fd);
    return 0;
}
