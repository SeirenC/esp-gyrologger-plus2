#include "battery.hpp"
#include "global_context.hpp"

extern "C" {
#include "driver/adc.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
}

// Always-on Plus2 battery reading via GPIO38 (ADC1 channel 2)
void battery_task(void *params) {
    adc1_config_width(ADC_WIDTH_BIT_12);
    adc1_config_channel_atten(ADC1_CHANNEL_2, ADC_ATTEN_DB_11);
    while (1) {
        int raw = adc1_get_raw(ADC1_CHANNEL_2);
        // 11dB attenuation: ~3.9V full scale; x2 for on-board voltage divider
        gctx.battery_voltage_mv = (int)((raw / 4095.0f) * 3900.0f * 2.0f);
        ESP_LOGI("bat", "raw=%d mv=%d", raw, gctx.battery_voltage_mv);
        vTaskDelay(5000 / portTICK_PERIOD_MS);
    }
}
