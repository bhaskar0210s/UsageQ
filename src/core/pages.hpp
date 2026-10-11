// Fixed-size arrays on their own anonymous VM pages. The scanner's large buffers live here
// instead of in malloc, so they start zeroed and go straight back to the OS when released,
// without fragmenting the heap the UI shares.
#pragma once

#include <cstddef>
#include <cstring>
#include <sys/mman.h>
#include <type_traits>
#include <utility>

namespace tt {

template <class T>
class PageArray {
    static_assert(std::is_trivially_copyable_v<T>, "PageArray holds plain data only");

public:
    PageArray() = default;
    explicit PageArray(size_t n) { allocate(n); }
    PageArray(const PageArray&) = delete;
    PageArray& operator=(const PageArray&) = delete;
    PageArray(PageArray&& o) noexcept { swap(o); }
    PageArray& operator=(PageArray&& o) noexcept {
        PageArray(std::move(o)).swap(*this);
        return *this;
    }
    ~PageArray() { release(); }

    // Replaces the contents with `n` zeroed elements. Returns false if the mapping failed.
    bool allocate(size_t n) {
        release();
        if (n == 0) return true;
        void* p = mmap(nullptr, n * sizeof(T), PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (p == MAP_FAILED) return false;
        data_ = static_cast<T*>(p);
        size_ = n;
        return true;
    }

    // Grows to `n` elements, keeping the existing ones.
    bool grow(size_t n) {
        if (n <= size_) return true;
        PageArray bigger;
        if (!bigger.allocate(n)) return false;
        if (size_) memcpy(bigger.data_, data_, size_ * sizeof(T));
        swap(bigger);
        return true;
    }

    void release() {
        if (data_) munmap(data_, size_ * sizeof(T));
        data_ = nullptr;
        size_ = 0;
    }

    void swap(PageArray& o) noexcept {
        std::swap(data_, o.data_);
        std::swap(size_, o.size_);
    }

    T* data() { return data_; }
    const T* data() const { return data_; }
    size_t size() const { return size_; }
    bool empty() const { return size_ == 0; }
    T& operator[](size_t i) { return data_[i]; }
    const T& operator[](size_t i) const { return data_[i]; }

private:
    T* data_ = nullptr;
    size_t size_ = 0;
};

}  // namespace tt
