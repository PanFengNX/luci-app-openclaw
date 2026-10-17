include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-openclaw
PKG_VERSION:=1.3.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=openclaw

LUCI_TITLE:=OpenClaw 助手 (openclaw)
LUCI_DESCRIPTION:=Install, run and manage the official OpenClaw gateway natively on OpenWrt \
	(procd + private Node.js runtime + npm package). Online version discovery with \
	engines.node enforcement; DeepSeek and Z.AI (GLM) model presets included. \
	Model picker installs the provider plugin and writes the API key; one-click \
	repair and 'openclaw doctor' support.
# luci-lua-runtime + luci-compat are required on OpenWrt 25.12 where the Lua
# controller bridge is no longer part of luci-base.
LUCI_DEPENDS:=+luci-base +luci-lua-runtime +luci-compat +curl +tar +jsonfilter

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=$(LUCI_TITLE)
  DEPENDS:=$(LUCI_DEPENDS)
  PKGARCH:=all
  URL:=https://github.com/openclaw/openclaw
endef

define Package/$(PKG_NAME)/description
	$(LUCI_DESCRIPTION)
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./luasrc/* $(PKG_BUILD_DIR)/ 2>/dev/null || true
	$(CP) ./root/* $(PKG_BUILD_DIR)/ 2>/dev/null || true
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci
	$(CP) ./luasrc/* $(1)/usr/lib/lua/luci/
	$(CP) ./root/* $(1)/
	$(INSTALL_DIR) $(1)/etc/uci-defaults
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
chmod +x /etc/init.d/openclaw 2>/dev/null
chmod +x /usr/libexec/istorec/openclaw.sh 2>/dev/null
chmod +x /usr/libexec/openclaw/*.sh 2>/dev/null
rm -f /tmp/luci-indexcache /tmp/luci-modulecache
exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
