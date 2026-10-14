#ifndef ANYKEY_MIC_NATIVE_H
#define ANYKEY_MIC_NATIVE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* 单实例；除音频回调外，以下接口必须由同一线程调用。 */
int am_init(void);
void am_shutdown(void);
const char *am_error(void);
int am_hid_count(void);
int am_hid_product_id(int index);
int am_hid_usage_page(int index);
const char *am_hid_path(int index);
int am_hid_open(int index);
int am_hid_read(uint8_t *data, int capacity);
int am_hid_write(const uint8_t *data, int length);
void am_hid_close(void);
int am_output_count(void);
const char *am_output_name(int index);
const char *am_output_id(int index);
int am_audio_open(int index);
/* 返回实际接受的帧数；队列满时丢弃新帧，不修改消费者读指针。 */
int am_audio_push(const int16_t *samples, int frames);
int am_audio_alive(void);
void am_audio_close(void);
int am_process_start(void);
int am_should_stop(void);
#ifdef __cplusplus
}
#endif
#endif

