FROM ubuntu:24.04

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Keep the SDK version and its SHA256 together when upgrading.
ARG FLUTTER_VERSION=3.47.8
ARG FLUTTER_SHA256=baf7dcc5a3dbba60fe863bf493a6cf203195621f7786eaa5a1bba02cd0d87dd2
ARG ANDROID_CMDLINE_TOOLS=15859902
ARG ANDROID_CMDLINE_TOOLS_SHA256=4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583
ARG ANDROID_API=36
ARG ANDROID_BUILD_TOOLS=36.0.0
ARG ANDROID_NDK=28.2.13676358
ARG ANDROID_CMAKE=3.22.1
ARG USER_UID=1000
ARG USER_GID=1000

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=Etc/UTC \
    JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 \
    FLUTTER_HOME=/opt/flutter \
    ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    HOME=/home/builder \
    PUB_CACHE=/home/builder/.pub-cache \
    GRADLE_USER_HOME=/home/builder/.gradle \
    CI=true \
    FLUTTER_SUPPRESS_ANALYTICS=true \
    DART_SUPPRESS_ANALYTICS=true
ENV PATH="/opt/flutter/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/opt/android-sdk/build-tools/${ANDROID_BUILD_TOOLS}:${JAVA_HOME}/bin:${PATH}"

RUN test "$(dpkg --print-architecture)" = amd64 \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       ca-certificates curl git unzip xz-utils zip \
       openjdk-17-jdk-headless libglu1-mesa libstdc++6 \
    && rm -rf /var/lib/apt/lists/* \
    && if id ubuntu >/dev/null 2>&1; then userdel --remove ubuntu; fi \
    && if ! getent group "${USER_GID}" >/dev/null; then groupadd --gid "${USER_GID}" builder; fi \
    && useradd --create-home --shell /bin/bash --uid "${USER_UID}" --gid "${USER_GID}" builder \
    && mkdir -p /opt/flutter /opt/android-sdk /workspace \
    && chown "${USER_UID}:${USER_GID}" /opt/flutter /opt/android-sdk /workspace

USER builder
WORKDIR /home/builder

RUN curl --fail --location --retry 5 --connect-timeout 30 \
      "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
      -o /tmp/flutter.tar.xz \
    && echo "${FLUTTER_SHA256}  /tmp/flutter.tar.xz" | sha256sum --check --strict \
    && tar --extract --xz --file=/tmp/flutter.tar.xz --directory=/opt/flutter --strip-components=1 --no-same-owner \
    && rm /tmp/flutter.tar.xz \
    && flutter config --no-analytics --enable-android --no-enable-linux-desktop --no-enable-web \
         --android-sdk="${ANDROID_HOME}" --jdk-dir="${JAVA_HOME}" \
    && dart --disable-analytics \
    && flutter precache --android \
    && flutter --version

RUN curl --fail --location --retry 5 --connect-timeout 30 \
      "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS}_latest.zip" \
      -o /tmp/android-tools.zip \
    && echo "${ANDROID_CMDLINE_TOOLS_SHA256}  /tmp/android-tools.zip" | sha256sum --check --strict \
    && mkdir -p "${ANDROID_HOME}/cmdline-tools" \
    && unzip -q /tmp/android-tools.zip -d /tmp/android-tools \
    && mv /tmp/android-tools/cmdline-tools "${ANDROID_HOME}/cmdline-tools/latest" \
    && rm -rf /tmp/android-tools /tmp/android-tools.zip \
    && (set +o pipefail; yes | sdkmanager --sdk_root="${ANDROID_HOME}" --licenses >/dev/null) \
    && sdkmanager --sdk_root="${ANDROID_HOME}" \
         "platform-tools" "platforms;android-${ANDROID_API}" \
         "build-tools;${ANDROID_BUILD_TOOLS}" "ndk;${ANDROID_NDK}" "cmake;${ANDROID_CMAKE}" \
    && mkdir -p "${PUB_CACHE}" "${GRADLE_USER_HOME}" "${HOME}/.android" \
    && java -version \
    && sdkmanager --sdk_root="${ANDROID_HOME}" --list_installed

LABEL io.flutter-android.builder.uid="${USER_UID}" \
      io.flutter-android.builder.gid="${USER_GID}" \
      io.flutter-android.flutter.version="${FLUTTER_VERSION}"

WORKDIR /workspace
CMD ["bash"]
