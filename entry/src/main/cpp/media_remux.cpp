#include <napi/native_api.h>
#include <multimedia/player_framework/native_avsource.h>
#include <multimedia/player_framework/native_avdemuxer.h>
#include <multimedia/player_framework/native_avmuxer.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <algorithm>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
void Check(OH_AVErrCode code, const char *stage)
{
    if (code != AV_ERR_OK) throw std::runtime_error(std::string(stage) + ":" + std::to_string(code));
}

struct Track {
    int fd = -1;
    OH_AVSource *source = nullptr;
    OH_AVDemuxer *demuxer = nullptr;
    OH_AVBuffer *buffer = nullptr;
    uint32_t inputIndex = 0;
    int32_t outputIndex = -1;
    OH_AVCodecBufferAttr attr = {};
    bool ended = false;
    ~Track()
    {
        if (buffer) OH_AVBuffer_Destroy(buffer);
        if (demuxer) OH_AVDemuxer_Destroy(demuxer);
        if (source) OH_AVSource_Destroy(source);
        if (fd >= 0) close(fd);
    }
    void Read()
    {
        Check(OH_AVDemuxer_ReadSampleBuffer(demuxer, inputIndex, buffer), "read-sample");
        Check(OH_AVBuffer_GetBufferAttr(buffer, &attr), "sample-attributes");
        ended = (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0;
    }
};

struct Output {
    int fd = -1;
    OH_AVMuxer *muxer = nullptr;
    bool started = false;
    ~Output()
    {
        if (muxer) {
            if (started) OH_AVMuxer_Stop(muxer);
            OH_AVMuxer_Destroy(muxer);
        }
        if (fd >= 0) close(fd);
    }
};

std::unique_ptr<Track> OpenTrack(const std::string &path, int32_t wanted, OH_AVMuxer *muxer)
{
    auto track = std::make_unique<Track>();
    track->fd = open(path.c_str(), O_RDONLY);
    struct stat info = {};
    if (track->fd < 0 || fstat(track->fd, &info) || info.st_size <= 0) throw std::runtime_error("track-file");
    track->source = OH_AVSource_CreateWithFD(track->fd, 0, info.st_size);
    if (!track->source) throw std::runtime_error("track-source");
    OH_AVFormat *summary = OH_AVSource_GetSourceFormat(track->source);
    int32_t count = 0;
    bool valid = summary && OH_AVFormat_GetIntValue(summary, OH_MD_KEY_TRACK_COUNT, &count);
    if (summary) OH_AVFormat_Destroy(summary);
    if (!valid || count < 1 || count > 32) throw std::runtime_error("track-metadata");
    for (int32_t index = 0; index < count; ++index) {
        OH_AVFormat *format = OH_AVSource_GetTrackFormat(track->source, index);
        int32_t type = -1;
        bool matched = format && OH_AVFormat_GetIntValue(format, OH_MD_KEY_TRACK_TYPE, &type) && type == wanted;
        if (!matched) {
            if (format) OH_AVFormat_Destroy(format);
            continue;
        }
        auto added = OH_AVMuxer_AddTrack(muxer, &track->outputIndex, format);
        OH_AVFormat_Destroy(format);
        Check(added, "add-track");
        track->inputIndex = index;
        track->demuxer = OH_AVDemuxer_CreateWithSource(track->source);
        if (!track->demuxer) throw std::runtime_error("track-demuxer");
        Check(OH_AVDemuxer_SelectTrackByID(track->demuxer, index), "select-track");
        track->buffer = OH_AVBuffer_Create(8 * 1024 * 1024);
        if (!track->buffer) throw std::runtime_error("sample-buffer");
        return track;
    }
    return nullptr;
}

void Remux(const std::string &video, const std::string &audio, const std::string &destination, bool requireAudio = false)
{
    Output output;
    output.fd = open(destination.c_str(), O_CREAT | O_TRUNC | O_RDWR, 0600);
    if (output.fd < 0) throw std::runtime_error("output-file");
    output.muxer = OH_AVMuxer_Create(output.fd, AV_OUTPUT_FORMAT_MPEG_4);
    if (!output.muxer) throw std::runtime_error("output-muxer");
    std::vector<std::unique_ptr<Track>> tracks;
    auto picture = OpenTrack(video, MEDIA_TYPE_VID, output.muxer);
    if (!picture) throw std::runtime_error("missing-video-track");
    tracks.push_back(std::move(picture));
    auto sound = OpenTrack(audio.empty() ? video : audio, MEDIA_TYPE_AUD, output.muxer);
    if ((requireAudio || !audio.empty()) && !sound) throw std::runtime_error("missing-audio-track");
    if (sound) tracks.push_back(std::move(sound));
    Check(OH_AVMuxer_Start(output.muxer), "start-muxer");
    output.started = true;
    for (auto &track : tracks) track->Read();
    int64_t origin = INT64_MAX;
    for (auto &track : tracks) if (!track->ended) origin = std::min(origin, track->attr.pts);
    size_t samples = 0;
    for (;;) {
        Track *next = nullptr;
        for (auto &track : tracks) {
            if (!track->ended && (!next || track->attr.pts < next->attr.pts)) next = track.get();
        }
        if (!next) break;
        if (next->attr.size > 0) {
            auto attr = next->attr;
            attr.pts -= origin;
            Check(OH_AVBuffer_SetBufferAttr(next->buffer, &attr), "set-timestamp");
            Check(OH_AVMuxer_WriteSampleBuffer(output.muxer, next->outputIndex, next->buffer), "write-sample");
            ++samples;
        }
        next->Read();
    }
    if (!samples) throw std::runtime_error("empty-video");
    Check(OH_AVMuxer_Stop(output.muxer), "finish-muxer");
    output.started = false;
}

struct Work {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string video, audio, output, error;
    bool requireAudio = false;
};

bool ReadString(napi_env env, napi_value value, std::string &result)
{
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok || length > 4096) return false;
    std::vector<char> bytes(length + 1);
    if (napi_get_value_string_utf8(env, value, bytes.data(), bytes.size(), &length) != napi_ok) return false;
    result.assign(bytes.data(), length);
    return result.find('\0') == std::string::npos;
}

napi_value Start(napi_env env, napi_callback_info info)
{
    size_t count = 4;
    napi_value values[4];
    napi_get_cb_info(env, info, &count, values, nullptr, nullptr);
    auto work = std::make_unique<Work>();
    if (count != 4 || napi_get_value_bool(env, values[3], &work->requireAudio) != napi_ok || !ReadString(env, values[0], work->video) || !ReadString(env, values[1], work->audio) ||
        !ReadString(env, values[2], work->output) || work->video.empty() || work->output.empty()) {
        napi_throw_type_error(env, nullptr, "Expected video, audio, output paths and audio requirement");
        return nullptr;
    }
    napi_value promise, resource;
    napi_create_promise(env, &work->deferred, &promise);
    napi_create_string_utf8(env, "QwitterRemux", NAPI_AUTO_LENGTH, &resource);
    auto status = napi_create_async_work(env, nullptr, resource,
        [](napi_env, void *data) {
            auto *job = static_cast<Work *>(data);
            try { Remux(job->video, job->audio, job->output, job->requireAudio); }
            catch (const std::exception &error) { job->error = error.what(); }
        },
        [](napi_env env, napi_status status, void *data) {
            std::unique_ptr<Work> job(static_cast<Work *>(data));
            napi_value result;
            if (status != napi_ok && job->error.empty()) job->error = "remux-cancelled";
            if (job->error.empty()) {
                napi_get_undefined(env, &result);
                napi_resolve_deferred(env, job->deferred, result);
            } else {
                unlink(job->output.c_str());
                napi_value message;
                napi_create_string_utf8(env, job->error.c_str(), NAPI_AUTO_LENGTH, &message);
                napi_create_error(env, nullptr, message, &result);
                napi_reject_deferred(env, job->deferred, result);
            }
            napi_delete_async_work(env, job->work);
        }, work.get(), &work->work);
    if (status == napi_ok) status = napi_queue_async_work(env, work->work);
    if (status != napi_ok) {
        if (work->work) napi_delete_async_work(env, work->work);
        napi_value message, error;
        napi_create_string_utf8(env, "remux-worker", NAPI_AUTO_LENGTH, &message);
        napi_create_error(env, nullptr, message, &error);
        napi_reject_deferred(env, work->deferred, error);
    } else { work.release(); }
    return promise;
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor property = {"remux", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr};
    napi_define_properties(env, exports, 1, &property);
    return exports;
}
napi_module module = {1, 0, nullptr, Init, "qwitter_media", nullptr, {0}};
__attribute__((constructor)) void Register() { napi_module_register(&module); }
}
