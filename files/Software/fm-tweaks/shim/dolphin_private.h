// dolphin_private.h - Dolphin's own (private) kitemviews headers, with private/protected opened so the hooks can read and flip members such as
// m_isHidden / m_selected / m_additionalInfoTextColor. This ties the code to the class LAYOUT of one Dolphin version: see shimOk() in common.h.
#pragma once
#include "common.h"
#define private public
#define protected public
#include "kitemviews/kitemliststyleoption.h"
#include "kitemviews/kstandarditemlistwidget.h"
#undef private
#undef protected
